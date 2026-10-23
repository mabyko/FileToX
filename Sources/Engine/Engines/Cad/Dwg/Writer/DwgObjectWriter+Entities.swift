// Entity records of the DWG object writer (ACadSharp 3.8.0 DwgObjectWriter.Entities), AC1032 branches.

import Foundation

extension ACad.DwgObjectWriter {
    typealias XYZ = ACad.XYZ
    typealias XY = ACad.XY

    /// `writeEntity`: the entity, then its attributes / vertices and their SEQEND.
    func writeEntity(_ entity: ACad.Entity) throws {
        var children: [ACad.Entity] = []
        var seqend: ACad.Seqend?
        try writeCommonEntityData(entity)
        switch entity {
        case let arc as ACad.Arc: writeArc(arc)
        case let circle as ACad.Circle: writeCircle(circle)
        case let dimension as ACad.Dimension:
            try writeCommonDimensionData(dimension)
            switch dimension {
            case let linear as ACad.DimensionLinear: writeDimensionLinear(linear)
            case let aligned as ACad.DimensionAligned: writeDimensionAligned(aligned)
            case let radius as ACad.DimensionRadius: writeDimensionRadius(radius)
            case let angular as ACad.DimensionAngular2Line: writeDimensionAngular2Line(angular)
            case let angular as ACad.DimensionAngular3Pt: writeDimensionAngular3Pt(angular)
            case let arc as ACad.DimensionArc: writeDimensionArc(arc)
            case let diameter as ACad.DimensionDiameter: writeDimensionDiameter(diameter)
            case let ordinate as ACad.DimensionOrdinate: writeDimensionOrdinate(ordinate)
            default: throw ACad.DwgError("Dimension not implemented : \(type(of: entity))")
            }
        case let ellipse as ACad.Ellipse: writeEllipse(ellipse)
        case let table as ACad.TableEntity: try writeTableEntity(table)
        case let insert as ACad.Insert:
            try writeInsert(insert)
            children.append(contentsOf: insert.attributes.entries as [ACad.Entity])
            seqend = insert.attributes.seqend
        case let face as ACad.Face3D: writeFace3D(face)
        case let hatch as ACad.Hatch: try writeHatch(hatch)
        case let leader as ACad.Leader: writeLeader(leader)
        case let line as ACad.Line: writeLine(line)
        case let polyline as ACad.LwPolyline: writeLwPolyline(polyline)
        case let mesh as ACad.Mesh: writeMesh(mesh)
        case let mline as ACad.MLine: writeMLine(mline)
        case let mtext as ACad.MText: writeMText(mtext)
        case let leader as ACad.MultiLeader: writeMultiLeader(leader)
        case let ole as ACad.Ole2Frame: writeOle2Frame(ole)
        case let underlay as ACad.PdfUnderlay: writePdfUnderlay(underlay)
        case let point as ACad.Point: writePoint(point)
        case let mesh as ACad.PolyfaceMesh:
            writePolyfaceMesh(mesh)
            children.append(contentsOf: mesh.faces.entries as [ACad.Entity])
            children.append(contentsOf: mesh.vertices.entries as [ACad.Entity])
            seqend = mesh.vertices.seqend
        case let pline as ACad.Polyline2D:
            writePolyline2D(pline)
            children.append(contentsOf: pline.vertices.entries as [ACad.Entity])
            seqend = pline.vertices.seqend
        case let pline as ACad.Polyline3D:
            writePolyline3D(pline)
            children.append(contentsOf: pline.vertices.entries as [ACad.Entity])
            seqend = pline.vertices.seqend
        case let mesh as ACad.PolygonMesh:
            writePolygonMesh(mesh)
            children.append(contentsOf: mesh.vertices.entries as [ACad.Entity])
            seqend = mesh.vertices.seqend
        case is ACad.Polyline:
            throw ACad.DwgError("Polyline not implemented : \(type(of: entity))")
        case let ray as ACad.Ray: writeRay(ray)
        case let shape as ACad.Shape: writeShape(shape)
        case let solid as ACad.Solid: writeSolid(solid)
        case is ACad.Solid3D: break
        case let spline as ACad.Spline: writeSpline(spline)
        case let image as ACad.CadWipeoutBase: writeCadImage(image)
        case let att as ACad.AttributeEntity: try writeCommonAttData(att)
        case let attdef as ACad.AttributeDefinition:
            try writeCommonAttData(attdef)
            // R2010+
            writer.writeByte(attdef.version)
            writer.writeVariableText(attdef.prompt)
        case let text as ACad.TextEntity: writeTextEntity(text)
        case let tolerance as ACad.Tolerance: writeTolerance(tolerance)
        case let vertex as ACad.Vertex2D: writeVertex2D(vertex)
        case let face as ACad.VertexFaceRecord: writeFaceRecord(face)
        case let vertex as ACad.Vertex:
            guard vertex is ACad.Vertex3D || vertex is ACad.VertexFaceMesh || vertex is ACad.PolygonMeshVertex else {
                throw ACad.DwgError("Vertex not implemented : \(type(of: entity))")
            }
            writeVertex(vertex)
        case let viewport as ACad.Viewport: writeViewport(viewport)
        case let xline as ACad.XLine: writeXLine(xline)
        default:
            throw ACad.DwgError("Entity not implemented : \(type(of: entity))")
        }
        try registerObject(entity)
        try writeChildEntities(children, seqend)
    }

    private func writeArc(_ arc: ACad.Arc) {
        writeCircle(arc)
        writer.writeBitDouble(arc.startAngle)
        writer.writeBitDouble(arc.endAngle)
    }

    private func writeCadImage(_ image: ACad.CadWipeoutBase) {
        writer.writeBitLong(image.classVersion)
        writer.write3BitDouble(image.insertPoint)
        writer.write3BitDouble(image.uVector)
        writer.write3BitDouble(image.vVector)
        writer.write2RawDouble(image.size)
        writer.writeBitShort(image.flags)
        writer.writeBit(image.clippingState)
        writer.writeByte(image.brightness)
        writer.writeByte(image.contrast)
        writer.writeByte(image.fade)
        // R2010+: ClipMode.Inside
        writer.writeBit(image.clipMode == 1)
        writer.writeBitShort(image.clipType)
        switch image.clipType {
        case ACad.ClipType.rectangular:
            writer.write2RawDouble(image.clipBoundaryVertices[0])
            writer.write2RawDouble(image.clipBoundaryVertices[1])
        case ACad.ClipType.polygonal:
            writer.writeBitLong(Int32(image.clipBoundaryVertices.count))
            for vertex in image.clipBoundaryVertices { writer.write2RawDouble(vertex) }
        default:
            break
        }
        writer.handleReference(.hardPointer, image.definition?.handle ?? 0)
        writer.handleReference(.hardOwnership, image.definitionReactor?.handle ?? 0)
        if let reactor = image.definitionReactor { enqueueValidObject(reactor) }
    }

    private func writeChildEntities(_ entities: [ACad.Entity], _ seqend: ACad.Seqend?) throws {
        guard !entities.isEmpty else { return }
        let prevHolder = prev
        let nextHolder = next
        prev = nil
        next = nil
        var curr = entities[0]
        for i in 1..<max(entities.count, 1) where i < entities.count {
            next = entities[i]
            try writeEntity(curr)
            prev = curr
            curr = next!
        }
        next = nil
        try writeEntity(curr)
        prev = prevHolder
        next = nextHolder
        if let seqend { try writeSeqend(seqend) }
    }

    private func writeCircle(_ circle: ACad.Circle) {
        writer.write3BitDouble(circle.center)
        writer.writeBitDouble(circle.radius)
        writer.writeBitThickness(circle.thickness)
        writer.writeBitExtrusion(circle.normal)
    }

    private func writeCommonAttData(_ att: ACad.AttributeBase) throws {
        writeTextEntity(att)
        // R2010+
        writer.writeByte(att.version)
        // R2018+
        if let mtext = att.mtext {
            writer.writeByte(att.attributeType)
            if att.attributeType == ACad.AttributeType.multiLine || att.attributeType == ACad.AttributeType.constantMultiLine {
                try writeEntityMode(mtext)
                writeMText(mtext)
                writer.writeBitShort(0)
            }
        } else {
            writer.writeByte(ACad.AttributeType.singleLine)
        }
        writer.writeVariableText(att.tag)
        writer.writeBitShort(0)
        writer.writeByte(UInt8(truncatingIfNeeded: att.flags))
        // R2007+
        writer.writeBit(att.isLocked)
    }

    private func writeCommonDimensionData(_ dimension: ACad.Dimension) throws {
        // R2010+
        writer.writeByte(dimension.version)
        writer.write3BitDouble(dimension.normal)
        writer.write2RawDouble(dimension.textMiddlePoint.xy)
        writer.writeBitDouble(dimension.insertionPoint.z)
        writer.writeByte(dimension.isTextUserDefinedLocation ? 0b00 : 0b01)
        writer.writeVariableText(dimension.text)
        writer.writeBitDouble(dimension.textRotation)
        writer.writeBitDouble(dimension.horizontalDirection)
        writer.write3BitDouble(XYZ(1, 1, 1))
        writer.writeBitDouble(0)
        // R2000+
        writer.writeBitShort(dimension.attachmentPoint)
        writer.writeBitShort(dimension.lineSpacingStyle)
        writer.writeBitDouble(dimension.lineSpacingFactor)
        writer.writeBitDouble(try dimension.measurement())
        // R2007+
        writer.writeBit(false)
        writer.writeBit(dimension.flipArrow1)
        writer.writeBit(dimension.flipArrow2)
        writer.write2RawDouble(dimension.insertionPoint.xy)
        writer.handleReference(.hardPointer, dimension.style.handle)
        writer.handleReference(.hardPointer, dimension.block?.handle ?? 0)
    }

    func writeCommonInsertData(_ insert: ACad.Insert) throws {
        writer.write3BitDouble(insert.insertPoint)
        // R2000+
        if insert.xScale == 1.0 && insert.yScale == 1.0 && insert.zScale == 1.0 {
            writer.write2Bits(3)
        } else if insert.xScale == insert.yScale && insert.xScale == insert.zScale {
            writer.write2Bits(2)
            writer.writeRawDouble(insert.xScale)
        } else if insert.xScale == 1.0 {
            writer.write2Bits(1)
            writer.writeBitDoubleWithDefault(insert.yScale, 1.0)
            writer.writeBitDoubleWithDefault(insert.zScale, 1.0)
        } else {
            writer.write2Bits(0)
            writer.writeRawDouble(insert.xScale)
            writer.writeBitDoubleWithDefault(insert.yScale, insert.xScale)
            writer.writeBitDoubleWithDefault(insert.zScale, insert.xScale)
        }
        writer.writeBitDouble(insert.rotation)
        writer.write3BitDouble(insert.normal)
        writer.writeBit(insert.hasAttributes)
        // R2004+
        if insert.hasAttributes { writer.writeBitLong(Int32(insert.attributes.count)) }
        if insert.isMultiple { writeMultipleData(insert) }
        writer.handleReference(.hardPointer, insert.block?.handle ?? 0)
        guard insert.hasAttributes else { return }
        // R2004+
        for att in insert.attributes { writer.handleReference(.hardOwnership, att.handle) }
        writer.handleReference(.hardOwnership, insert.attributes.seqend?.handle ?? 0)
    }

    private func writeMultipleData(_ insert: ACad.Insert) {
        writer.writeBitShort(Int16(truncatingIfNeeded: insert.columnCount))
        writer.writeBitShort(Int16(truncatingIfNeeded: insert.rowCount))
        writer.writeBitDouble(insert.columnSpacing)
        writer.writeBitDouble(insert.rowSpacing)
    }

    private func writeDimensionAligned(_ d: ACad.DimensionAligned) {
        writer.write3BitDouble(d.firstPoint)
        writer.write3BitDouble(d.secondPoint)
        writer.write3BitDouble(d.definitionPoint)
        writer.writeBitDouble(d.extLineRotation)
    }

    private func writeDimensionAngular2Line(_ d: ACad.DimensionAngular2Line) {
        writer.write2RawDouble(d.dimensionArc.xy)
        writer.write3BitDouble(d.firstPoint)
        writer.write3BitDouble(d.secondPoint)
        writer.write3BitDouble(d.angleVertex)
        writer.write3BitDouble(d.definitionPoint)
    }

    private func writeDimensionAngular3Pt(_ d: ACad.DimensionAngular3Pt) {
        writer.write3BitDouble(d.definitionPoint)
        writer.write3BitDouble(d.firstPoint)
        writer.write3BitDouble(d.secondPoint)
        writer.write3BitDouble(d.angleVertex)
    }

    private func writeDimensionArc(_ d: ACad.DimensionArc) {
        writer.write3BitDouble(d.definitionPoint)
        writer.write3BitDouble(d.firstPoint)
        writer.write3BitDouble(d.secondPoint)
        writer.write3BitDouble(d.center)
        writer.writeBit(d.isPartial)
        writer.writeBitDouble(d.startAngle)
        writer.writeBitDouble(d.endAngle)
        writer.writeBit(d.hasLeader)
        writer.write3BitDouble(d.leaderPoint1)
        writer.write3BitDouble(d.leaderPoint2)
    }

    private func writeDimensionDiameter(_ d: ACad.DimensionDiameter) {
        writer.write3BitDouble(d.angleVertex)
        writer.write3BitDouble(d.definitionPoint)
        writer.writeBitDouble(d.leaderLength)
    }

    private func writeDimensionLinear(_ d: ACad.DimensionLinear) {
        writeDimensionAligned(d)
        writer.writeBitDouble(d.rotation)
    }

    private func writeDimensionOrdinate(_ d: ACad.DimensionOrdinate) {
        writer.write3BitDouble(d.definitionPoint)
        writer.write3BitDouble(d.featureLocation)
        writer.write3BitDouble(d.leaderEndpoint)
        writer.writeByte(d.isOrdinateTypeX ? 1 : 0)
    }

    private func writeDimensionRadius(_ d: ACad.DimensionRadius) {
        writer.write3BitDouble(d.definitionPoint)
        writer.write3BitDouble(d.angleVertex)
        writer.writeBitDouble(d.leaderLength)
    }

    private func writeEllipse(_ ellipse: ACad.Ellipse) {
        writer.write3BitDouble(ellipse.center)
        writer.write3BitDouble(ellipse.majorAxisEndPoint)
        writer.write3BitDouble(ellipse.normal)
        writer.writeBitDouble(ellipse.radiusRatio)
        writer.writeBitDouble(ellipse.startParameter)
        writer.writeBitDouble(ellipse.endParameter)
    }

    private func writeFace3D(_ face: ACad.Face3D) {
        // R2000+
        let noFlags = face.flags == 0
        writer.writeBit(noFlags)
        let zIsZero = face.firstCorner.z == 0.0
        writer.writeBit(zIsZero)
        writer.writeRawDouble(face.firstCorner.x)
        writer.writeRawDouble(face.firstCorner.y)
        if !zIsZero { writer.writeRawDouble(face.firstCorner.z) }
        writer.write3BitDoubleWithDefault(face.secondCorner, face.firstCorner)
        writer.write3BitDoubleWithDefault(face.thirdCorner, face.secondCorner)
        writer.write3BitDoubleWithDefault(face.fourthCorner, face.thirdCorner)
        if !noFlags { writer.writeBitShort(face.flags) }
    }

    private func writeFaceRecord(_ face: ACad.VertexFaceRecord) {
        writer.writeBitShort(face.index1)
        writer.writeBitShort(face.index2)
        writer.writeBitShort(face.index3)
        writer.writeBitShort(face.index4)
    }

    private func writeHatch(_ hatch: ACad.Hatch) throws {
        // R2004+
        let gradient = hatch.gradientColor
        writer.writeBitLong(gradient.enabled ? 1 : 0)
        writer.writeBitLong(gradient.reserved)
        writer.writeBitDouble(gradient.angle)
        writer.writeBitDouble(gradient.shift)
        writer.writeBitLong(gradient.isSingleColorGradient ? 1 : 0)
        writer.writeBitDouble(gradient.colorTint)
        writer.writeBitLong(Int32(gradient.colors.count))
        for color in gradient.colors {
            writer.writeBitDouble(color.value)
            writer.writeCmColor(color.color)
        }
        writer.writeVariableText(gradient.name)
        // Common
        writer.writeBitDouble(hatch.elevation)
        writer.write3BitDouble(hatch.normal)
        writer.writeVariableText(hatch.pattern.name)
        writer.writeBit(hatch.isSolid)
        writer.writeBit(hatch.isAssociative)
        writer.writeBitLong(Int32(hatch.paths.count))
        var hasDerivedBoundary = false
        for path in hatch.paths {
            writer.writeBitLong(path.flags)
            if path.flags & ACad.BoundaryPathFlags.derived != 0 { hasDerivedBoundary = true }
            if path.flags & ACad.BoundaryPathFlags.polyline != 0 {
                // `Edges.First() as Polyline`: a missing or different first edge is a null reference.
                guard let first = path.edges.first, case let .polyline(vertices, isClosed, _) = first else {
                    throw ACad.DxfWriteError.nullReference
                }
                // HasBulge is computed from the bulges in ACadSharp.
                let hasBulge = vertices.contains { $0.z != 0 }
                writer.writeBit(hasBulge)
                writer.writeBit(isClosed)
                writer.writeBitLong(Int32(vertices.count))
                for vertex in vertices {
                    writer.write2RawDouble(XY(vertex.x, vertex.y))
                    if hasBulge { writer.writeBitDouble(vertex.z) }
                }
            } else {
                writer.writeBitLong(Int32(path.edges.count))
                for edge in path.edges {
                    writer.writeByte(UInt8(truncatingIfNeeded: edge.typeCode))
                    switch edge {
                    case let .line(start, end):
                        writer.write2RawDouble(start)
                        writer.write2RawDouble(end)
                    case let .arc(center, radius, startAngle, endAngle, counterClockWise):
                        writer.write2RawDouble(center)
                        writer.writeBitDouble(radius)
                        writer.writeBitDouble(startAngle)
                        writer.writeBitDouble(endAngle)
                        writer.writeBit(counterClockWise)
                    case let .ellipse(center, majorAxisEndPoint, radiusRatio, startAngle, endAngle, counterClockWise):
                        writer.write2RawDouble(center)
                        writer.write2RawDouble(majorAxisEndPoint)
                        writer.writeBitDouble(radiusRatio)
                        writer.writeBitDouble(startAngle)
                        writer.writeBitDouble(endAngle)
                        writer.writeBit(counterClockWise)
                    case let .spline(spline):
                        writer.writeBitLong(spline.degree)
                        writer.writeBit(spline.isRational)
                        writer.writeBit(spline.isPeriodic)
                        writer.writeBitLong(Int32(spline.knots.count))
                        writer.writeBitLong(Int32(spline.controlPoints.count))
                        for k in spline.knots { writer.writeBitDouble(k) }
                        for p in spline.controlPoints {
                            writer.write2RawDouble(p.xy)
                            if spline.isRational { writer.writeBitDouble(p.z) }
                        }
                        // R2010+
                        writer.writeBitLong(Int32(spline.fitPoints.count))
                        if !spline.fitPoints.isEmpty {
                            for fp in spline.fitPoints { writer.write2RawDouble(fp) }
                            writer.write2RawDouble(spline.startTangent)
                            writer.write2RawDouble(spline.endTangent)
                        }
                    case .polyline:
                        throw ACad.DwgError("Unrecognized Boundary type: ACadSharp.Entities.Hatch+BoundaryPath")
                    }
                }
            }
            writer.writeBitLong(Int32(path.entities.count))
            for e in path.entities { writer.handleReference(.softPointer, e.handle) }
        }
        writer.writeBitShort(hatch.style)
        writer.writeBitShort(hatch.patternType)
        if !hatch.isSolid {
            let pattern = hatch.pattern
            writer.writeBitDouble(hatch.patternAngle)
            writer.writeBitDouble(hatch.patternScale)
            writer.writeBit(hatch.isDouble)
            writer.writeBitShort(Int16(truncatingIfNeeded: pattern.lines.count))
            for line in pattern.lines {
                writer.writeBitDouble(line.angle)
                writer.write2BitDouble(line.basePoint)
                writer.write2BitDouble(line.offset)
                writer.writeBitShort(Int16(truncatingIfNeeded: line.dashLengths.count))
                for dl in line.dashLengths { writer.writeBitDouble(dl) }
            }
        }
        if hasDerivedBoundary { writer.writeBitDouble(hatch.pixelSize) }
        writer.writeBitLong(Int32(hatch.seedPoints.count))
        for sp in hatch.seedPoints { writer.write2RawDouble(sp) }
    }

    /// `writeInsert`: the column / row data is written a second time for MINSERT, as in ACadSharp.
    private func writeInsert(_ insert: ACad.Insert) throws {
        try writeCommonInsertData(insert)
        if insert.isMultiple { writeMultipleData(insert) }
    }

    private func writeLeader(_ leader: ACad.Leader) {
        writer.writeBit(false)
        writer.writeBitShort(leader.creationType)
        writer.writeBitShort(leader.pathType)
        writer.writeBitLong(Int32(leader.vertices.count))
        for v in leader.vertices { writer.write3BitDouble(v) }
        writer.write3BitDouble(leader.vertices.first ?? .zero)
        writer.write3BitDouble(leader.normal)
        writer.write3BitDouble(leader.horizontalDirection)
        writer.write3BitDouble(leader.blockOffset)
        // R14+
        writer.write3BitDouble(leader.annotationOffset)
        writer.writeBit(leader.hookLineDirection == ACad.HookLineDirection.same)
        writer.writeBit(leader.arrowHeadEnabled)
        // R2000+
        writer.writeBitShort(0)
        writer.writeBit(false)
        writer.writeBit(false)
        writer.handleReference(.hardPointer, 0)
        writer.handleReference(.hardPointer, leader.style.handle)
    }

    private func writeLeaderLine(_ leaderLine: ACad.MultiLeaderObjectContextData.LeaderLine) {
        writer.writeBitLong(Int32(leaderLine.points.count))
        for point in leaderLine.points { writer.write3BitDouble(point) }
        writer.writeBitLong(leaderLine.breakInfoCount)
        if leaderLine.breakInfoCount > 0 {
            // `SegmentIndex` / `StartEndPoints` of the 3.8.0 model.
            let pairs = leaderLine.breakInfo.flatMap(\.pairs)
            writer.writeBitLong(leaderLine.breakInfo.last?.segmentIndex ?? 0)
            writer.writeBitLong(Int32(pairs.count))
            for pair in pairs {
                writer.write3BitDouble(pair.startPoint)
                writer.write3BitDouble(pair.endPoint)
            }
        }
        writer.writeBitLong(leaderLine.index)
        // R2010+
        writer.writeBitShort(leaderLine.pathType)
        writer.writeCmColor(leaderLine.lineColor)
        writer.handleReference(.hardPointer, leaderLine.lineType?.handle ?? 0)
        writer.writeBitLong(Int32(leaderLine.lineWeight.rawValue))
        writer.writeBitDouble(leaderLine.arrowheadSize)
        writer.handleReference(.hardPointer, leaderLine.arrowhead?.handle ?? 0)
        writer.writeBitLong(Int32(Int16(truncatingIfNeeded: leaderLine.overrideFlags)))
    }

    private func writeLeaderRoot(_ root: ACad.MultiLeaderObjectContextData.LeaderRoot) {
        writer.writeBit(root.contentValid)
        writer.writeBit(true)
        writer.write3BitDouble(root.connectionPoint)
        writer.write3BitDouble(root.direction)
        writer.writeBitLong(Int32(root.breakStartEndPointsPairs.count))
        for pair in root.breakStartEndPointsPairs {
            writer.write3BitDouble(pair.startPoint)
            writer.write3BitDouble(pair.endPoint)
        }
        writer.writeBitLong(root.leaderIndex)
        writer.writeBitDouble(root.landingDistance)
        writer.writeBitLong(Int32(root.lines.count))
        for line in root.lines { writeLeaderLine(line) }
        // R2010+
        writer.writeBitShort(root.textAttachmentDirection)
    }

    private func writeLine(_ line: ACad.Line) {
        // R2000+
        let flag = line.startPoint.z == 0.0 && line.endPoint.z == 0.0
        writer.writeBit(flag)
        writer.writeRawDouble(line.startPoint.x)
        writer.writeBitDoubleWithDefault(line.endPoint.x, line.startPoint.x)
        writer.writeRawDouble(line.startPoint.y)
        writer.writeBitDoubleWithDefault(line.endPoint.y, line.startPoint.y)
        if !flag {
            writer.writeRawDouble(line.startPoint.z)
            writer.writeBitDoubleWithDefault(line.endPoint.z, line.startPoint.z)
        }
        writer.writeBitThickness(line.thickness)
        writer.writeBitExtrusion(line.normal)
    }

    private func writeLwPolyline(_ pline: ACad.LwPolyline) {
        var nbulges = false
        var ndiffwidth = false
        for item in pline.vertices {
            if !nbulges && item.bulge != 0.0 { nbulges = true }
            if !ndiffwidth && (item.startWidth != 0.0 || item.endWidth != 0.0) { ndiffwidth = true }
        }
        var flags: Int16 = 0
        if pline.flags & 128 != 0 { flags |= 0x100 } // LwPolylineFlags.Plinegen
        if pline.flags & 1 != 0 { flags |= 0x200 } // LwPolylineFlags.Closed
        if pline.constantWidth != 0.0 { flags |= 0x4 }
        if pline.elevation != 0.0 { flags |= 0x8 }
        if pline.thickness != 0.0 { flags |= 2 }
        if pline.normal != XYZ.axisZ { flags |= 1 }
        if nbulges { flags |= 0x10 }
        if ndiffwidth { flags |= 0x20 }
        writer.writeBitShort(flags)
        if pline.constantWidth != 0.0 { writer.writeBitDouble(pline.constantWidth) }
        if pline.elevation != 0.0 { writer.writeBitDouble(pline.elevation) }
        if pline.thickness != 0.0 { writer.writeBitDouble(pline.thickness) }
        if pline.normal != XYZ.axisZ { writer.write3BitDouble(pline.normal) }
        writer.writeBitLong(Int32(pline.vertices.count))
        if nbulges { writer.writeBitLong(Int32(pline.vertices.count)) }
        if ndiffwidth { writer.writeBitLong(Int32(pline.vertices.count)) }
        // R2000+
        if !pline.vertices.isEmpty {
            var last = pline.vertices[0]
            writer.write2RawDouble(last.location)
            for j in 1..<pline.vertices.count where j < pline.vertices.count {
                let curr = pline.vertices[j]
                writer.write2BitDoubleWithDefault(curr.location, last.location)
                last = curr
            }
        }
        if nbulges {
            for v in pline.vertices { writer.writeBitDouble(v.bulge) }
        }
        if ndiffwidth {
            for v in pline.vertices {
                writer.writeBitDouble(v.startWidth)
                writer.writeBitDouble(v.endWidth)
            }
        }
    }

    private func writeMesh(_ mesh: ACad.Mesh) {
        writer.writeBitShort(mesh.version)
        writer.writeBit(mesh.blendCrease)
        writer.writeBitLong(mesh.subdivisionLevel)
        writer.writeBitLong(Int32(mesh.vertices.count))
        for vertex in mesh.vertices { writer.write3BitDouble(vertex) }
        writer.writeBitLong(Int32(mesh.faces.reduce(0) { $0 + 1 + $1.count }))
        for face in mesh.faces {
            writer.writeBitLong(Int32(face.count))
            for index in face { writer.writeBitLong(index) }
        }
        writer.writeBitLong(Int32(mesh.edges.count))
        for edge in mesh.edges {
            writer.writeBitLong(edge.start)
            writer.writeBitLong(edge.end)
        }
        writer.writeBitLong(Int32(mesh.edges.count))
        for edge in mesh.edges { writer.writeBitDouble(edge.crease ?? 0) }
        writer.writeBitLong(0)
    }

    private func writeMLine(_ mline: ACad.MLine) {
        writer.writeBitDouble(mline.scaleFactor)
        writer.writeByte(UInt8(truncatingIfNeeded: mline.justification))
        writer.write3BitDouble(mline.startPoint)
        writer.write3BitDouble(mline.normal)
        writer.writeBitShort(mline.flags & 2 != 0 ? 3 : 1) // MLineFlags.Closed
        let nlines = mline.vertices.first?.segments.count ?? 0
        writer.writeByte(UInt8(truncatingIfNeeded: nlines))
        writer.writeBitShort(Int16(truncatingIfNeeded: mline.vertices.count))
        for v in mline.vertices {
            writer.write3BitDouble(v.position)
            writer.write3BitDouble(v.direction)
            writer.write3BitDouble(v.miter)
            for i in 0..<nlines {
                let element = v.segments[i]
                writer.writeBitShort(Int16(truncatingIfNeeded: element.parameters.count))
                for p in element.parameters { writer.writeBitDouble(p) }
                writer.writeBitShort(Int16(truncatingIfNeeded: element.areaFillParameters.count))
                for p in element.areaFillParameters { writer.writeBitDouble(p) }
            }
        }
        writer.handleReference(.hardPointer, mline.style?.handle ?? 0)
    }

    func writeMText(_ mtext: ACad.MText) {
        writer.write3BitDouble(mtext.insertPoint)
        writer.write3BitDouble(mtext.normal)
        writer.write3BitDouble(mtext.alignmentPoint)
        writer.writeBitDouble(mtext.rectangleWidth)
        // R2007+
        writer.writeBitDouble(mtext.rectangleHeight)
        writer.writeBitDouble(mtext.height)
        writer.writeBitShort(mtext.attachmentPoint)
        writer.writeBitShort(mtext.drawingDirection)
        writer.writeBitDouble(0)
        writer.writeBitDouble(0)
        writer.writeVariableText(mtext.value)
        writer.handleReference(.hardPointer, mtext.style.handle)
        // R2000+
        writer.writeBitShort(mtext.lineSpacingStyle)
        writer.writeBitDouble(mtext.lineSpacing)
        writer.writeBit(false)
        // R2004+
        writer.writeBitLong(mtext.backgroundFillFlags)
        // UseBackgroundFillColor (1), or TextFrame (16) after AC1027.
        if mtext.backgroundFillFlags & 1 != 0 || version > .ac1027 && mtext.backgroundFillFlags & 16 > 0 {
            writer.writeBitDouble(mtext.backgroundScale)
            writer.writeCmColor(mtext.backgroundColor)
            writer.writeBitLong(Int32(mtext.backgroundTransparency.value))
        }
        // R2018+
        writer.writeBit(!mtext.isAnnotative)
        if mtext.isAnnotative { return }
        writer.writeBitShort(4)
        writer.writeBit(true)
        writer.handleReference(.hardPointer, 0)
        writer.writeBitLong(Int32(mtext.attachmentPoint))
        writer.write3BitDouble(mtext.alignmentPoint)
        writer.write3BitDouble(mtext.insertPoint)
        writer.writeBitDouble(mtext.rectangleWidth)
        writer.writeBitDouble(mtext.rectangleHeight)
        writer.writeBitDouble(mtext.horizontalWidth)
        writer.writeBitDouble(mtext.verticalHeight)
        let columns = mtext.columnData
        writer.writeBitShort(columns.columnType)
        if columns.columnType != 0 {
            writer.writeBitLong(columns.columnCount)
            writer.writeBitDouble(columns.width)
            writer.writeBitDouble(columns.gutter)
            writer.writeBit(columns.autoHeight)
            writer.writeBit(columns.flowReversed)
            if !columns.autoHeight && columns.columnType == 2 { // ColumnType.DynamicColumns
                for h in columns.heights { writer.writeBitDouble(h) }
            }
        }
    }

    private func writeMultiLeader(_ leader: ACad.MultiLeader) {
        // R2010+
        writer.writeBitShort(2)
        writeMultiLeaderAnnotContextSubObject(true, leader.contextData)
        writer.handleReference(.hardPointer, leader.style.handle)
        writer.writeBitLong(leader.propertyOverrideFlags)
        writer.writeBitShort(leader.pathType)
        writer.writeCmColor(leader.lineColor)
        writer.handleReference(.hardPointer, leader.leaderLineType.handle)
        writer.writeBitLong(Int32(leader.leaderLineWeight.rawValue))
        writer.writeBit(leader.enableLanding)
        writer.writeBit(leader.enableDogleg)
        writer.writeBitDouble(leader.landingDistance)
        writer.handleReference(.hardPointer, leader.arrowhead?.handle ?? 0)
        writer.writeBitDouble(leader.arrowheadSize)
        writer.writeBitShort(leader.contentType)
        writer.handleReference(.hardPointer, leader.textStyle.handle)
        writer.writeBitShort(leader.textLeftAttachment)
        writer.writeBitShort(leader.textRightAttachment)
        writer.writeBitShort(leader.textAngle)
        writer.writeBitShort(leader.textAlignment)
        writer.writeCmColor(leader.textColor)
        writer.writeBit(leader.textFrame)
        writer.handleReference(.hardPointer, leader.blockContent?.handle ?? 0)
        writer.writeCmColor(leader.blockContentColor)
        writer.write3BitDouble(leader.blockContentScale)
        writer.writeBitDouble(leader.blockContentRotation)
        writer.writeBitShort(leader.blockContentConnection)
        writer.writeBit(leader.enableAnnotationScale)
        writer.writeBitLong(Int32(leader.blockAttributes.count))
        for attribute in leader.blockAttributes {
            writer.handleReference(.hardPointer, attribute.attributeDefinition?.handle ?? 0)
            writer.writeVariableText(attribute.text)
            writer.writeBitShort(attribute.index)
            writer.writeBitDouble(attribute.width)
        }
        writer.writeBit(leader.textDirectionNegative)
        writer.writeBitShort(leader.textAligninIPE)
        writer.writeBitShort(leader.textAttachmentPoint)
        writer.writeBitDouble(leader.scaleFactor)
        // R2010+
        writer.writeBitShort(leader.textAttachmentDirection)
        writer.writeBitShort(leader.textBottomAttachment)
        writer.writeBitShort(leader.textTopAttachment)
        // R2013+
        writer.writeBit(leader.extendedToText)
    }

    func writeMultiLeaderAnnotContextSubObject(_ writeLeaderRootsCount: Bool, _ context: ACad.MultiLeaderObjectContextData) {
        let leaderRootCount = context.leaderRoots.count
        if writeLeaderRootsCount {
            writer.writeBitLong(Int32(leaderRootCount))
        } else {
            writer.writeBitLong(0)
            for _ in 0..<5 { writer.writeBit(false) }
            writer.writeBit(leaderRootCount == 2)
            writer.writeBit(leaderRootCount == 1)
        }
        for root in context.leaderRoots { writeLeaderRoot(root) }
        writer.writeBitDouble(context.scaleFactor)
        writer.write3BitDouble(context.contentBasePoint)
        writer.writeBitDouble(context.textHeight)
        writer.writeBitDouble(context.arrowheadSize)
        writer.writeBitDouble(context.landingGap)
        writer.writeBitShort(context.textLeftAttachment)
        writer.writeBitShort(context.textRightAttachment)
        writer.writeBitShort(context.textAlignment)
        writer.writeBitShort(context.blockContentConnection)
        writer.writeBit(context.hasTextContents)
        if context.hasTextContents {
            writer.writeVariableText(context.textLabel)
            writer.write3BitDouble(context.textNormal)
            writer.handleReference(.hardPointer, context.textStyle?.handle ?? 0)
            writer.write3BitDouble(context.textLocation)
            writer.write3BitDouble(context.direction)
            writer.writeBitDouble(context.textRotation)
            writer.writeBitDouble(context.boundaryWidth)
            writer.writeBitDouble(context.boundaryHeight)
            writer.writeBitDouble(context.lineSpacingFactor)
            writer.writeBitShort(context.lineSpacing)
            writer.writeCmColor(context.textColor)
            writer.writeBitShort(context.textAttachmentPoint)
            writer.writeBitShort(context.flowDirection)
            writer.writeCmColor(context.backgroundFillColor)
            writer.writeBitDouble(context.backgroundScaleFactor)
            writer.writeBitLong(context.backgroundTransparency)
            writer.writeBit(context.backgroundFillEnabled)
            writer.writeBit(context.backgroundMaskFillOn)
            writer.writeBitShort(context.columnType)
            writer.writeBit(context.textHeightAutomatic)
            writer.writeBitDouble(context.columnWidth)
            writer.writeBitDouble(context.columnGutter)
            writer.writeBit(context.columnFlowReversed)
            writer.writeBitLong(Int32(context.columnSizes.count))
            for size in context.columnSizes { writer.writeBitDouble(size) }
            writer.writeBit(context.wordBreak)
            writer.writeBit(false)
        } else if context.hasContentsBlock {
            writer.writeBit(context.hasContentsBlock)
            writer.handleReference(.softPointer, context.blockContent?.handle ?? 0)
            writer.write3BitDouble(context.blockContentNormal)
            writer.write3BitDouble(context.blockContentLocation)
            writer.write3BitDouble(context.blockContentScale)
            writer.writeBitDouble(context.blockContentRotation)
            writer.writeCmColor(context.blockContentColor)
            // M00, M10, M20, M30, M01 … (column by column) of the row-major 4×4 matrix.
            let m = context.transformationMatrix
            for column in 0..<4 {
                for row in 0..<4 { writer.writeBitDouble(m[row * 4 + column]) }
            }
        }
        writer.write3BitDouble(context.basePoint)
        writer.write3BitDouble(context.baseDirection)
        writer.write3BitDouble(context.baseVertical)
        writer.writeBit(context.normalReversed)
        // R2010+
        writer.writeBitShort(context.textTopAttachment)
        writer.writeBitShort(context.textBottomAttachment)
    }

    private func writeOle2Frame(_ ole: ACad.Ole2Frame) {
        writer.writeBitShort(ole.version)
        // R2000+
        writer.writeBitShort(0)
        writer.writeBitLong(Int32(ole.binaryData.count))
        writer.writeBytes([UInt8](ole.binaryData))
        // R2000+
        writer.writeByte(3)
    }

    private func writePdfUnderlay(_ underlay: ACad.PdfUnderlay) {
        writer.write3BitDouble(underlay.normal)
        writer.write3BitDouble(underlay.insertPoint)
        writer.writeBitDouble(underlay.rotation)
        writer.writeBitDouble(underlay.xScale)
        writer.writeBitDouble(underlay.yScale)
        writer.writeBitDouble(underlay.zScale)
        writer.writeByte(underlay.flags)
        writer.writeByte(underlay.contrast)
        writer.writeByte(underlay.fade)
        writer.handleReference(.hardPointer, underlay.definition?.handle ?? 0)
        writer.writeBitLong(Int32(underlay.clipBoundaryVertices.count))
        for v in underlay.clipBoundaryVertices { writer.write2RawDouble(v) }
    }

    private func writePoint(_ point: ACad.Point) {
        writer.write3BitDouble(point.location)
        writer.writeBitThickness(point.thickness)
        writer.writeBitExtrusion(point.normal)
        writer.writeBitDouble(point.rotation)
    }

    private func writePolyfaceMesh(_ fm: ACad.PolyfaceMesh) {
        writer.writeBitShort(Int16(truncatingIfNeeded: fm.vertices.count))
        writer.writeBitShort(Int16(truncatingIfNeeded: fm.faces.count))
        // R2004+
        writer.writeBitLong(Int32(fm.vertices.count + fm.faces.count))
        for v in fm.vertices { writer.handleReference(.softPointer, v.handle) }
        for f in fm.faces { writer.handleReference(.softPointer, f.handle) }
        writer.handleReference(.softPointer, fm.vertices.seqend?.handle ?? 0)
    }

    private func writePolygonMesh(_ pline: ACad.PolygonMesh) {
        writer.writeBitShort(pline.flags)
        writer.writeBitShort(pline.smoothSurface)
        writer.writeBitShort(pline.mVertexCount)
        writer.writeBitShort(pline.nVertexCount)
        writer.writeBitShort(pline.mSmoothSurfaceDensity)
        writer.writeBitShort(pline.nSmoothSurfaceDensity)
        // R2004+
        writer.writeBitLong(Int32(pline.vertices.count))
        for vertex in pline.vertices { writer.handleReference(.hardOwnership, vertex.handle) }
        writer.handleReference(.hardOwnership, pline.vertices.seqend?.handle ?? 0)
    }

    private func writePolyline2D(_ pline: ACad.Polyline2D) {
        writer.writeBitShort(pline.flags)
        writer.writeBitShort(pline.smoothSurface)
        writer.writeBitDouble(pline.startWidth)
        writer.writeBitDouble(pline.endWidth)
        writer.writeBitThickness(pline.thickness)
        writer.writeBitDouble(pline.elevation)
        writer.writeBitExtrusion(pline.normal)
        // R2004+
        writer.writeBitLong(Int32(pline.vertices.count))
        for v in pline.vertices { writer.handleReference(.hardOwnership, v.handle) }
        writer.handleReference(.hardOwnership, pline.vertices.seqend?.handle ?? 0)
    }

    private func writePolyline3D(_ pline: ACad.Polyline3D) {
        writer.writeByte(0)
        writer.writeByte(pline.flags & 1 != 0 ? 1 : 0) // ClosedPolylineOrClosedPolygonMeshInM
        // R2004+
        writer.writeBitLong(Int32(pline.vertices.count))
        for vertex in pline.vertices { writer.handleReference(.hardOwnership, vertex.handle) }
        writer.handleReference(.hardOwnership, pline.vertices.seqend?.handle ?? 0)
    }

    private func writeRay(_ ray: ACad.Ray) {
        writer.write3BitDouble(ray.startPoint)
        writer.write3BitDouble(ray.direction)
    }

    private func writeSeqend(_ seqend: ACad.Seqend) throws {
        let prevHolder = prev
        let nextHolder = next
        prev = nil
        next = nil
        try writeCommonEntityData(seqend)
        try registerObject(seqend)
        prev = prevHolder
        next = nextHolder
    }

    private func writeShape(_ shape: ACad.Shape) {
        writer.write3BitDouble(shape.insertionPoint)
        writer.writeBitDouble(shape.size)
        writer.writeBitDouble(shape.rotation)
        writer.writeBitDouble(shape.relativeXScale)
        writer.writeBitDouble(shape.obliqueAngle)
        writer.writeBitDouble(shape.thickness)
        writer.writeBitShort(Int16(truncatingIfNeeded: shape.shapeIndex))
        writer.write3BitDouble(shape.normal)
        writer.handleReference(.hardPointer, 0)
    }

    private func writeSolid(_ solid: ACad.Solid) {
        writer.writeBitThickness(solid.thickness)
        writer.writeBitDouble(solid.firstCorner.z)
        writer.writeRawDouble(solid.firstCorner.x)
        writer.writeRawDouble(solid.firstCorner.y)
        writer.writeRawDouble(solid.secondCorner.x)
        writer.writeRawDouble(solid.secondCorner.y)
        writer.writeRawDouble(solid.thirdCorner.x)
        writer.writeRawDouble(solid.thirdCorner.y)
        writer.writeRawDouble(solid.fourthCorner.x)
        writer.writeRawDouble(solid.fourthCorner.y)
        writer.writeBitExtrusion(solid.normal)
    }

    /// `writeSpline` (R2013+): the scenario and flags; changes `Flags1` like ACadSharp.
    private func writeSpline(_ spline: ACad.Spline) {
        let scenario: Int32
        if spline.knotParametrization == 15 || spline.fitPoints.isEmpty { // KnotParametrization.Custom
            scenario = 1
            spline.flags1 &= ~8 // UseKnotParameter
        } else {
            scenario = 2
            spline.flags1 |= 1 | 8 // MethodFitPoints | UseKnotParameter
        }
        writer.writeBitLong(scenario)
        writer.writeBitLong(spline.flags1)
        writer.writeBitLong(spline.knotParametrization)
        writer.writeBitLong(spline.degree)
        let flag = !spline.weights.isEmpty
        switch scenario {
        case 1:
            writer.writeBit(spline.flags & 4 != 0) // Rational
            writer.writeBit(spline.flags & 1 != 0) // Closed
            writer.writeBit(spline.flags & 2 != 0) // Periodic
            writer.writeBitDouble(spline.knotTolerance)
            writer.writeBitDouble(spline.controlPointTolerance)
            writer.writeBitLong(Int32(spline.knots.count))
            writer.writeBitLong(Int32(spline.controlPoints.count))
            writer.writeBit(flag)
            for k in spline.knots { writer.writeBitDouble(k) }
            for i in spline.controlPoints.indices {
                writer.write3BitDouble(spline.controlPoints[i])
                if flag { writer.writeBitDouble(spline.weights[i]) }
            }
        default:
            writer.writeBitDouble(spline.fitTolerance)
            writer.write3BitDouble(spline.startTangent)
            writer.write3BitDouble(spline.endTangent)
            writer.writeBitLong(Int32(spline.fitPoints.count))
            for fp in spline.fitPoints { writer.write3BitDouble(fp) }
        }
    }

    private func writeTextEntity(_ text: ACad.TextEntity) {
        var dataFlags: UInt8 = 0
        if text.insertPoint.z == 0.0 { dataFlags |= 0b1 }
        if text.alignmentPoint == XYZ.zero { dataFlags |= 0b10 }
        if text.obliqueAngle == 0.0 { dataFlags |= 0b100 }
        if text.rotation == 0.0 { dataFlags |= 0b1000 }
        if text.widthFactor == 1.0 { dataFlags |= 0b1_0000 }
        if text.mirror == 0 { dataFlags |= 0b10_0000 }
        if text.horizontalAlignment == 0 { dataFlags |= 0b100_0000 }
        if text.verticalAlignment == 0 { dataFlags |= 0b1000_0000 }
        writer.writeByte(dataFlags)
        if dataFlags & 0b1 == 0 { writer.writeRawDouble(text.insertPoint.z) }
        writer.writeRawDouble(text.insertPoint.x)
        writer.writeRawDouble(text.insertPoint.y)
        if dataFlags & 0x2 == 0 {
            writer.writeBitDoubleWithDefault(text.alignmentPoint.x, text.insertPoint.x)
            writer.writeBitDoubleWithDefault(text.alignmentPoint.y, text.insertPoint.y)
        }
        writer.writeBitExtrusion(text.normal)
        writer.writeBitThickness(text.thickness)
        if dataFlags & 0x4 == 0 { writer.writeRawDouble(text.obliqueAngle) }
        if dataFlags & 0x8 == 0 { writer.writeRawDouble(text.rotation) }
        writer.writeRawDouble(text.height)
        if dataFlags & 0x10 == 0 { writer.writeRawDouble(text.widthFactor) }
        writer.writeVariableText(text.value)
        if dataFlags & 0x20 == 0 { writer.writeBitShort(text.mirror) }
        if dataFlags & 0x40 == 0 { writer.writeBitShort(text.horizontalAlignment) }
        if dataFlags & 0x80 == 0 { writer.writeBitShort(text.verticalAlignment) }
        writer.handleReference(.hardPointer, text.style.handle)
    }

    private func writeTolerance(_ tolerance: ACad.Tolerance) {
        writer.write3BitDouble(tolerance.insertionPoint)
        writer.write3BitDouble(tolerance.direction)
        writer.write3BitDouble(tolerance.normal)
        writer.writeVariableText(tolerance.text)
        writer.handleReference(.hardPointer, tolerance.style.handle)
    }

    private func writeVertex(_ vertex: ACad.Vertex) {
        writer.writeByte(UInt8(truncatingIfNeeded: vertex.flags))
        writer.write3BitDouble(vertex.location)
    }

    private func writeVertex2D(_ vertex: ACad.Vertex2D) {
        writer.writeByte(UInt8(truncatingIfNeeded: vertex.flags))
        writer.writeBitDouble(vertex.location.x)
        writer.writeBitDouble(vertex.location.y)
        writer.writeBitDouble(0.0)
        if vertex.startWidth != 0.0 && vertex.endWidth == vertex.startWidth {
            writer.writeBitDouble(0.0 - vertex.startWidth)
        } else {
            writer.writeBitDouble(vertex.startWidth)
            writer.writeBitDouble(vertex.endWidth)
        }
        writer.writeBitDouble(vertex.bulge)
        // R2010+
        writer.writeBitLong(vertex.id)
        writer.writeBitDouble(vertex.curveTangent)
    }

    private func writeViewport(_ viewport: ACad.Viewport) {
        writer.write3BitDouble(viewport.center)
        writer.writeBitDouble(viewport.width)
        writer.writeBitDouble(viewport.height)
        // R2000+
        writer.write3BitDouble(viewport.viewTarget)
        writer.write3BitDouble(viewport.viewDirection)
        writer.writeBitDouble(viewport.twistAngle)
        writer.writeBitDouble(viewport.viewHeight)
        writer.writeBitDouble(viewport.lensLength)
        writer.writeBitDouble(viewport.frontClipPlane)
        writer.writeBitDouble(viewport.backClipPlane)
        writer.writeBitDouble(viewport.snapAngle)
        writer.write2RawDouble(viewport.viewCenter)
        writer.write2RawDouble(viewport.snapBase)
        writer.write2RawDouble(viewport.snapSpacing)
        writer.write2RawDouble(viewport.gridSpacing)
        writer.writeBitShort(viewport.circleZoomPercent)
        // R2007+
        writer.writeBitShort(viewport.majorGridLineFrequency)
        // R2000+
        writer.writeBitLong(Int32(viewport.frozenLayers.count))
        writer.writeBitLong(viewport.status)
        writer.writeVariableText("")
        writer.writeByte(viewport.renderMode)
        writer.writeBit(viewport.displayUcsIcon)
        writer.writeBit(viewport.ucsPerViewport)
        writer.write3BitDouble(viewport.ucsOrigin)
        writer.write3BitDouble(viewport.ucsXAxis)
        writer.write3BitDouble(viewport.ucsYAxis)
        writer.writeBitDouble(viewport.elevation)
        writer.writeBitShort(viewport.ucsOrthographicType)
        // R2004+
        writer.writeBitShort(viewport.shadePlotMode)
        // R2007+
        writer.writeBit(viewport.useDefaultLighting)
        writer.writeByte(viewport.defaultLightingType)
        writer.writeBitDouble(viewport.brightness)
        writer.writeBitDouble(viewport.contrast)
        writer.writeCmColor(viewport.ambientLightColor)
        // R2000+: frozen layers (R2004+ soft pointers), clip boundary
        for layer in viewport.frozenLayers { writer.handleReference(.softPointer, layer.handle) }
        writer.handleReference(.hardPointer, viewport.boundary?.handle ?? 0)
        // R2000+: named UCS, base UCS
        writer.handleReference(.hardPointer, 0)
        writer.handleReference(.hardPointer, 0)
        // R2007+: background, visual style, shade plot, sun
        writer.handleReference(.softPointer, 0)
        writer.handleReference(.hardPointer, 0)
        writer.handleReference(.softPointer, 0)
        writer.handleReference(.hardOwnership, 0)
    }

    private func writeXLine(_ xline: ACad.XLine) {
        writer.write3BitDouble(xline.firstPoint)
        writer.write3BitDouble(xline.direction)
    }

    // ───────────────────────── Tables (ACAD_TABLE) ─────────────────────────

    private func writeTableEntity(_ table: ACad.TableEntity) throws {
        try writeCommonInsertData(table)
        // R2010+
        writer.writeByte(0)
        writer.handleReference(.softPointer, 0)
        writer.writeBitLong(0)
        // R2013+
        writer.writeBitLong(0)
        try writeTableContent(table.content)
        writer.writeBitShort(38)
        writer.write3BitDouble(table.horizontalDirection)
        writer.writeBitLong(table.hasBreadData ? 1 : 0)
        if table.hasBreadData {
            let data = table.breakData
            writer.writeBitLong(data.flags)
            writer.writeBitLong(data.flowDirection)
            writer.writeBitDouble(data.breakSpacing)
            writer.writeBitLong(0)
            writer.writeBitLong(0)
            writer.writeBitLong(Int32(data.heights.count))
            for height in data.heights {
                writer.write3BitDouble(height.position)
                writer.writeBitDouble(height.height)
                writer.writeBitLong(0)
            }
        }
        writer.writeBitLong(Int32(table.breakRowRanges.count))
        for range in table.breakRowRanges {
            writer.write3BitDouble(range.position)
            writer.writeBitLong(range.startRowIndex)
            writer.writeBitLong(range.endRowIndex)
        }
    }

    private func writeTableContent(_ content: ACad.TableContent) throws {
        writer.writeVariableText(content.name)
        writer.writeVariableText(content.description)
        writer.writeBitLong(Int32(content.columns.count))
        for column in content.columns {
            writer.writeVariableText(column.name)
            writer.writeBitLong(column.customData)
            writer.writeBitLong(Int32(column.customDataCollection.count))
            for entry in column.customDataCollection { try writeCustomTableData(entry) }
            writeCellStyle(column.cellStyleOverride)
            writer.writeBitLong(column.cellStyle?.id ?? 0)
            writer.writeBitDouble(column.width)
        }
        writer.writeBitLong(Int32(content.rows.count))
        for row in content.rows {
            writer.writeBitLong(Int32(row.cells.count))
            for cell in row.cells { try writeTableCell(cell) }
            writer.writeBitLong(row.customData)
            writer.writeBitLong(Int32(row.customDataCollection.count))
            for entry in row.customDataCollection { try writeCustomTableData(entry) }
            writeCellStyle(row.cellStyleOverride)
            writer.writeBitLong(row.cellStyle?.id ?? 0)
            writer.writeBitDouble(row.height)
        }
        writer.writeBitLong(0)
        writeCellStyle(content.cellStyleOverride)
        writer.writeBitLong(Int32(content.mergedCellRanges.count))
        for range in content.mergedCellRanges {
            writer.writeBitLong(range.topRowIndex)
            writer.writeBitLong(range.leftColumnIndex)
            writer.writeBitLong(range.bottomRowIndex)
            writer.writeBitLong(range.rightColumnIndex)
        }
        writer.handleReference(.hardPointer, content.style.handle)
    }

    private func writeTableCell(_ cell: ACad.TableEntity.Cell) throws {
        writer.writeBitLong(cell.stateFlags)
        writer.writeVariableText(cell.toolTip)
        writer.writeBitLong(cell.customData)
        writer.writeBitLong(Int32(cell.customDataCollection.count))
        for entry in cell.customDataCollection { try writeCustomTableData(entry) }
        writer.writeBitLong(cell.hasLinkedData ? 1 : 0)
        if cell.hasLinkedData {
            writer.handleReference(.undefined, 0)
            writer.writeBitLong(0)
            writer.writeBitLong(0)
            writer.writeBitLong(0)
            throw ACad.DwgError("Exception of type 'System.Exception' was thrown.")
        }
        writer.writeBitLong(Int32(cell.contents.count))
        for content in cell.contents { try writeTableCellContent(content) }
        writeCellStyle(cell.styleOverride)
        writer.writeBitLong(cell.style?.id ?? 0)
        writer.writeBitLong(0)
    }

    private func writeTableCellContent(_ content: ACad.TableEntity.CellContent) throws {
        writer.writeBitLong(content.contentType)
        switch content.contentType {
        case 1: try writeCadValue(content.cadValue) // TableCellContentType.Value
        case 2, 4: writer.handleReference(.hardPointer, 0) // Field, Block
        default: break
        }
        writer.writeBitLong(0)
        writer.writeBitShort(content.format.hasData ? 1 : 0)
        if content.format.hasData { writeCellContentFormatPublic(content.format) }
    }

    private func writeCustomTableData(_ entry: ACad.TableEntity.CustomDataEntry) throws {
        writer.writeVariableText(entry.name)
        try writeCadValue(entry.value)
    }
}
