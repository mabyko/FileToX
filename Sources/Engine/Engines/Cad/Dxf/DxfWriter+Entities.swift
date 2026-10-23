// Entity groups of the DXF writer (ACadSharp 3.8.0 DxfSectionWriterBase.Entities).

import Foundation

extension ACad.DxfWriter {
    typealias E = ACad

    /// `writeEntity`.
    func writeEntity(_ entity: ACad.Entity) throws {
        guard try isEntitySupported(entity) else { return }
        try write(0, entity.objectName)
        try writeCommonObjectData(entity)
        try writeCommonEntityData(entity)
        switch entity {
        case let arc as E.Arc: try writeArc(arc)
        case let circle as E.Circle: try writeCircle(circle)
        case let dimension as E.Dimension: try writeDimension(dimension)
        case let ellipse as E.Ellipse: try writeEllipse(ellipse)
        case let face as E.Face3D: try writeFace3D(face)
        case let hatch as E.Hatch: try writeHatch(hatch)
        case let insert as E.Insert: try writeInsert(insert)
        case let leader as E.Leader: try writeLeader(leader)
        case let line as E.Line: try writeLine(line)
        case let polyline as E.LwPolyline: try writeLwPolyline(polyline)
        case let mesh as E.Mesh: try writeMesh(mesh)
        case let mline as E.MLine: try writeMLine(mline)
        case let mtext as E.MText: try writeMText(mtext)
        case let leader as E.MultiLeader: try writeMultiLeader(leader)
        case let ole as E.Ole2Frame: try writeOle2Frame(ole)
        case let underlay as E.PdfUnderlay: try writePdfUnderlay(underlay)
        case let point as E.Point: try writePoint(point)
        case let polyline as E.Polyline: try writePolyline(polyline)
        case let image as E.RasterImage: try writeCadImage(image)
        case let ray as E.Ray: try writeRay(ray)
        case let shape as E.Shape: try writeShape(shape)
        case let solid as E.Solid: try writeSolid(solid)
        case let spline as E.Spline: try writeSpline(spline)
        case let text as E.TextEntity: try writeTextEntity(text)
        case let tolerance as E.Tolerance: try writeTolerance(tolerance)
        case let vertex as E.Vertex: try writeVertex(vertex)
        case let viewport as E.Viewport: try writeViewport(viewport)
        case let wipeout as E.Wipeout: try writeCadImage(wipeout)
        case let xline as E.XLine: try writeXLine(xline)
        default: throw ACad.DxfWriteError("Entity not implemented \(type(of: entity))")
        }
        try writeExtendedData(entity)
    }

    private func isEntitySupported(_ entity: ACad.Entity) throws -> Bool {
        guard try entity.isValid(format: .dxf, version: version) else {
            notify("Invalid entity \(type(of: entity)) with handle \(entity.handle)")
            return false
        }
        switch entity {
        case is E.Seqend, is E.UnknownEntity, is E.MechanicalEntity, is E.Wall:
            return false
        case is E.Shape:
            return writeShapes
        case is E.ProxyEntity, is E.TableEntity, is E.Solid3D, is E.CadBody, is E.Region:
            notify("Entity type not implemented \(type(of: entity))")
            return false
        default:
            return true
        }
    }

    private func writeArc(_ arc: ACad.Arc) throws {
        try writeCircle(arc)
        try write(100, ACad.DxfSubclassMarker.arc)
        try write(50, arc.startAngle, angle: true)
        try write(51, arc.endAngle, angle: true)
    }

    private func writeAttributeBase(_ att: ACad.AttributeBase) throws {
        try write(2, att.tag)
        try write(70, att.flags)
        try write(73, Int16(0))
        if att.verticalAlignment != 0 { try write(74, att.verticalAlignment) }
        if version > .ac1027, att.attributeType != ACad.AttributeType.singleLine {
            try write(71, Int16(att.attributeType))
            try write(72, Int16(0))
            try write(11, att.alignmentPoint)
            if let mtext = att.mtext {
                try write(101, "Embedded Object")
                try writeMText(mtext, writeSubclass: false)
            }
        }
    }

    private func writeBoundaryPath(_ path: ACad.Hatch.BoundaryPath) throws {
        try write(92, path.flags)
        if path.flags & ACad.BoundaryPathFlags.polyline == 0 {
            try write(93, Int32(path.edges.count))
        }
        for edge in path.edges { try writeHatchBoundaryPathEdge(edge) }
        try write(97, Int32(path.entities.count))
        for entity in path.entities { try writeHandle(330, entity) }
    }

    private func writeCadImage(_ image: ACad.CadWipeoutBase) throws {
        try write(100, image.subclassMarker)
        try write(90, image.classVersion)
        try write(10, image.insertPoint)
        try write(11, image.uVector)
        try write(12, image.vVector)
        try write(13, image.size)
        try writeHandle(340, image.definition)
        try write(70, image.flags)
        try write(280, image.clippingState)
        try write(281, image.brightness)
        try write(282, image.contrast)
        try write(283, image.fade)
        if let reactor = image.definitionReactor {
            try writeHandle(360, reactor)
            heldObjects.append(reactor)
        }
        try write(71, image.clipType)
        if image.clipType == ACad.ClipType.polygonal {
            try write(91, Int32(image.clipBoundaryVertices.count + 1))
            for vertex in image.clipBoundaryVertices { try write(14, vertex) }
            guard let first = image.clipBoundaryVertices.first else {
                throw ACad.DxfWriteError("Sequence contains no elements")
            }
            try write(14, first)
        } else {
            try write(91, Int32(image.clipBoundaryVertices.count))
            for vertex in image.clipBoundaryVertices { try write(14, vertex) }
        }
    }

    private func writeCircle(_ circle: ACad.Circle) throws {
        try write(100, ACad.DxfSubclassMarker.circle)
        try write(10, circle.center)
        try write(39, circle.thickness)
        try write(40, circle.radius)
        try write(210, circle.normal)
    }

    private func writeDimension(_ dim: ACad.Dimension) throws {
        try write(100, ACad.DxfSubclassMarker.dimension)
        try writeName(2, dim.block?.name)
        try write(10, dim.definitionPoint)
        try write(11, dim.textMiddlePoint)
        try write(12, dim.insertionPoint)
        try write(53, dim.textRotation, angle: true)
        try write(70, dim.flags)
        try write(71, dim.attachmentPoint)
        try write(72, dim.lineSpacingStyle)
        try write(41, dim.lineSpacingFactor)
        if let text = dim.text, !text.isEmpty { try write(1, text) }
        try write(210, dim.normal)
        try writeName(3, dim.style.name)
        switch dim {
        case let aligned as E.DimensionAligned:
            try write(100, ACad.DxfSubclassMarker.alignedDimension)
            try write(13, aligned.firstPoint)
            try write(14, aligned.secondPoint)
            if let linear = aligned as? E.DimensionLinear {
                try write(50, linear.rotation, angle: true)
                try write(100, ACad.DxfSubclassMarker.linearDimension)
            }
        case let radius as E.DimensionRadius:
            try write(100, ACad.DxfSubclassMarker.radialDimension)
            try write(15, radius.angleVertex)
            try write(40, radius.leaderLength)
        case let diameter as E.DimensionDiameter:
            try write(100, ACad.DxfSubclassMarker.diametricDimension)
            try write(15, diameter.angleVertex)
            try write(40, diameter.leaderLength)
        case let angular as E.DimensionAngular2Line:
            try write(100, ACad.DxfSubclassMarker.angular2LineDimension)
            try write(13, angular.firstPoint)
            try write(14, angular.secondPoint)
            try write(15, angular.angleVertex)
            try write(16, angular.dimensionArc)
        case let angular as E.DimensionAngular3Pt:
            try write(100, ACad.DxfSubclassMarker.angular3PointDimension)
            try write(13, angular.firstPoint)
            try write(14, angular.secondPoint)
            try write(15, angular.angleVertex)
        case let arc as E.DimensionArc:
            try write(100, ACad.DxfSubclassMarker.arcDimension)
            try write(13, arc.firstPoint)
            try write(14, arc.secondPoint)
            try write(15, arc.center)
            try write(70, Int16(arc.isPartial ? 1 : 0))
            try write(40, arc.startAngle)
            try write(41, arc.endAngle)
            try write(71, Int16(arc.hasLeader ? 1 : 0))
            if arc.hasLeader {
                try write(16, arc.leaderPoint1)
                try write(17, arc.leaderPoint2)
            }
        case let ordinate as E.DimensionOrdinate:
            try write(100, ACad.DxfSubclassMarker.ordinateDimension)
            try write(13, ordinate.featureLocation)
            try write(14, ordinate.leaderEndpoint)
        default:
            throw ACad.DxfWriteError("Dimension type not implemented \(type(of: dim))")
        }
    }

    private func writeEllipse(_ ellipse: ACad.Ellipse) throws {
        try write(100, ACad.DxfSubclassMarker.ellipse)
        try write(10, ellipse.center)
        try write(11, ellipse.majorAxisEndPoint)
        try write(210, ellipse.normal)
        try write(39, ellipse.thickness)
        try write(40, ellipse.radiusRatio)
        try write(41, ellipse.startParameter)
        try write(42, ellipse.endParameter)
    }

    private func writeFace3D(_ face: ACad.Face3D) throws {
        try write(100, ACad.DxfSubclassMarker.face3d)
        try write(10, face.firstCorner)
        try write(11, face.secondCorner)
        try write(12, face.thirdCorner)
        try write(13, face.fourthCorner)
        try write(70, face.flags)
    }

    private func writeHatch(_ hatch: ACad.Hatch) throws {
        try write(100, ACad.DxfSubclassMarker.hatch)
        try write(10, Int32(0))
        try write(20, Int32(0))
        try write(30, hatch.elevation)
        try write(210, hatch.normal)
        try write(2, hatch.pattern.name)
        try write(70, Int16(hatch.isSolid ? 1 : 0))
        try write(71, Int16(hatch.isAssociative ? 1 : 0))
        try write(91, Int32(hatch.paths.count))
        for path in hatch.paths { try writeBoundaryPath(path) }
        try writeHatchPattern(hatch)
        if !hatch.isSolid || hatch.paths.contains(where: { $0.flags & ACad.BoundaryPathFlags.derived != 0 }) || hatch.pixelSize != 0 {
            try write(47, hatch.pixelSize)
        }
        try write(98, Int32(hatch.seedPoints.count))
        for point in hatch.seedPoints { try write(10, point) }
    }

    /// Boundary arc angles: a full sweep stays distinct without leaving -360 … 360.
    private func writeHatchBoundaryAngles(_ startAngle: Double, _ endAngle: Double) throws {
        var start = ACad.MathHelper.radToDeg(startAngle, normalize: true, absolute: false)
        var end = ACad.MathHelper.radToDeg(endAngle, normalize: true, absolute: false)
        if ACad.MathHelper.isEqual(abs(endAngle - startAngle), ACad.MathHelper.twoPI) {
            let sweep = endAngle > startAngle ? 360.0 : -360.0
            if abs(start + sweep) > 360 { start -= sweep }
            end = start + sweep
        }
        try write(50, start)
        try write(51, end)
    }

    private func writeHatchBoundaryPathEdge(_ edge: ACad.Hatch.BoundaryPath.Edge) throws {
        if case .polyline = edge {} else { try write(72, Int16(edge.typeCode)) }
        switch edge {
        case let .arc(center, radius, startAngle, endAngle, counterClockWise):
            try write(10, center)
            try write(40, radius)
            try writeHatchBoundaryAngles(startAngle, endAngle)
            try write(73, Int16(counterClockWise ? 1 : 0))
        case let .ellipse(center, majorAxisEndPoint, radiusRatio, startAngle, endAngle, counterClockWise):
            try write(10, center)
            try write(11, majorAxisEndPoint)
            try write(40, radiusRatio)
            try writeHatchBoundaryAngles(startAngle, endAngle)
            try write(73, Int16(counterClockWise ? 1 : 0))
        case let .line(start, end):
            try write(10, start)
            try write(11, end)
        case let .polyline(vertices, isClosed, _):
            // HasBulge is computed from the bulges in ACadSharp.
            let hasBulge = vertices.contains { $0.z != 0 }
            try write(72, Int16(hasBulge ? 1 : 0))
            try write(73, Int16(isClosed ? 1 : 0))
            try write(93, Int32(vertices.count))
            for vertex in vertices {
                try write(10, vertex.xy)
                if hasBulge { try write(42, vertex.z) }
            }
        case let .spline(spline):
            try write(94, spline.degree)
            try write(73, Int16(spline.isRational ? 1 : 0))
            try write(74, Int16(spline.isPeriodic ? 1 : 0))
            try write(95, Int32(spline.knots.count))
            try write(96, Int32(spline.controlPoints.count))
            for knot in spline.knots { try write(40, knot) }
            for point in spline.controlPoints {
                try write(10, point.x)
                try write(20, point.y)
                if spline.isRational { try write(42, point.z) }
            }
            try write(97, Int32(spline.fitPoints.count))
            for point in spline.fitPoints {
                try write(11, point.x)
                try write(21, point.y)
            }
            if !spline.fitPoints.isEmpty {
                try write(12, spline.startTangent.x)
                try write(22, spline.startTangent.y)
                try write(13, spline.endTangent.x)
                try write(23, spline.endTangent.y)
            }
        }
    }

    private func writeHatchPattern(_ hatch: ACad.Hatch) throws {
        try write(75, hatch.style)
        try write(76, hatch.patternType)
        guard !hatch.isSolid else { return }
        try write(52, ACad.MathHelper.radToDeg(hatch.patternAngle))
        try write(41, hatch.patternScale)
        try write(77, Int16(hatch.isDouble ? 1 : 0))
        try write(78, Int16(truncatingIfNeeded: hatch.pattern.lines.count))
        for line in hatch.pattern.lines {
            try write(53, ACad.MathHelper.radToDeg(line.angle))
            try write(43, line.basePoint.x)
            try write(44, line.basePoint.y)
            try write(45, line.offset.x)
            try write(46, line.offset.y)
            try write(79, Int16(truncatingIfNeeded: line.dashLengths.count))
            for dash in line.dashLengths { try write(49, dash) }
        }
    }

    private func writeInsert(_ insert: ACad.Insert) throws {
        try write(100, insert.subclassMarker)
        try writeName(2, insert.block?.name)
        try write(10, insert.insertPoint)
        try write(41, insert.xScale)
        try write(42, insert.yScale)
        try write(43, insert.zScale)
        try write(50, insert.rotation, angle: true)
        try write(70, Int16(truncatingIfNeeded: insert.columnCount))
        try write(71, Int16(truncatingIfNeeded: insert.rowCount))
        try write(44, insert.columnSpacing)
        try write(45, insert.rowSpacing)
        try write(210, insert.normal)
        if insert.hasAttributes {
            try write(66, Int32(1))
            for attribute in insert.attributes { try writeEntity(attribute) }
            try writeSeqend(insert.attributes.seqend)
        }
    }

    private func writeLeader(_ leader: ACad.Leader) throws {
        try write(100, ACad.DxfSubclassMarker.leader)
        try writeName(3, leader.style.name)
        try write(71, Int16(leader.arrowHeadEnabled ? 1 : 0))
        try write(72, leader.pathType)
        try write(73, leader.creationType)
        try write(74, Int16(leader.hookLineDirection == ACad.HookLineDirection.same ? 1 : 0))
        try write(75, Int16(try leader.hasHookline() ? 1 : 0))
        try write(40, leader.textHeight)
        try write(41, leader.textWidth)
        try write(76, Int32(leader.vertices.count))
        for vertex in leader.vertices { try write(10, vertex) }
        try write(210, leader.normal)
        try write(211, leader.horizontalDirection)
        try write(212, leader.blockOffset)
        try write(213, leader.annotationOffset)
    }

    private func writeLine(_ line: ACad.Line) throws {
        try write(100, ACad.DxfSubclassMarker.line)
        try write(10, line.startPoint)
        try write(11, line.endPoint)
        try write(39, line.thickness)
        try write(210, line.normal)
    }

    private func writeLwPolyline(_ polyline: ACad.LwPolyline) throws {
        try write(100, ACad.DxfSubclassMarker.lwPolyline)
        try write(90, Int32(polyline.vertices.count))
        try write(70, polyline.flags)
        if polyline.constantWidth != 0 { try write(43, polyline.constantWidth) }
        try write(38, polyline.elevation)
        try write(39, polyline.thickness)
        for vertex in polyline.vertices {
            try write(10, vertex.location)
            try write(40, vertex.startWidth)
            try write(41, vertex.endWidth)
            try write(42, vertex.bulge)
        }
        try write(210, polyline.normal)
    }

    private func writeMesh(_ mesh: ACad.Mesh) throws {
        try write(100, ACad.DxfSubclassMarker.mesh)
        try write(71, mesh.version)
        try write(72, Int16(mesh.blendCrease ? 1 : 0))
        try write(91, mesh.subdivisionLevel)
        try write(92, Int32(mesh.vertices.count))
        for vertex in mesh.vertices { try write(10, vertex) }
        try write(93, Int32(mesh.faces.count + mesh.faces.reduce(0) { $0 + $1.count }))
        for face in mesh.faces {
            try write(90, Int32(face.count))
            for index in face { try write(90, index) }
        }
        try write(94, Int32(mesh.edges.count))
        for edge in mesh.edges {
            try write(90, edge.start)
            try write(90, edge.end)
        }
        try write(95, Int32(mesh.edges.count))
        for edge in mesh.edges { try write(140, edge.crease ?? 0) }
        try write(90, Int32(0))
    }

    private func writeMLine(_ mline: ACad.MLine) throws {
        try write(100, ACad.DxfSubclassMarker.mLine)
        try writeName(2, mline.style?.name)
        try writeHandle(340, mline.style)
        try write(40, mline.scaleFactor)
        try write(70, mline.justification)
        try write(71, mline.flags)
        try write(72, Int16(truncatingIfNeeded: mline.vertices.count))
        if let style = mline.style { try write(73, Int16(truncatingIfNeeded: style.elements.count)) }
        try write(10, mline.startPoint)
        try write(210, mline.normal)
        for vertex in mline.vertices {
            try write(11, vertex.position)
            try write(12, vertex.direction)
            try write(13, vertex.miter)
            for segment in vertex.segments {
                try write(74, Int16(truncatingIfNeeded: segment.parameters.count))
                for parameter in segment.parameters { try write(41, parameter) }
                try write(75, Int16(truncatingIfNeeded: segment.areaFillParameters.count))
                for parameter in segment.areaFillParameters { try write(42, parameter) }
            }
        }
    }

    private func writeMText(_ mtext: ACad.MText, writeSubclass: Bool = true) throws {
        if writeSubclass { try write(100, ACad.DxfSubclassMarker.mText) }
        try write(10, mtext.insertPoint)
        try write(40, mtext.height)
        try write(41, mtext.rectangleWidth)
        try write(44, mtext.lineSpacing)
        if version >= .ac1021 { try write(46, mtext.rectangleHeight) }
        try write(71, mtext.attachmentPoint)
        try write(72, mtext.drawingDirection)
        try writeLongTextValue(1, 3, mtext.value)
        try writeName(7, mtext.style.name)
        try write(73, mtext.lineSpacingStyle)
        try write(11, mtext.alignmentPoint)
        try write(210, mtext.normal)
        guard mtext.columnData.columnType != 0, version >= .ac1032 else { return }
        try write(101, "Embedded Object")
        try write(70, Int16(1))
        try write(10, mtext.alignmentPoint)
        try write(11, mtext.insertPoint)
        try write(40, mtext.rectangleWidth)
        try write(41, mtext.rectangleHeight)
        try write(42, mtext.horizontalWidth)
        try write(43, mtext.verticalHeight)
        try write(71, mtext.columnData.columnType)
        try write(72, Int16(truncatingIfNeeded: mtext.columnData.columnCount))
        try write(44, mtext.columnData.width)
        try write(45, mtext.columnData.gutter)
        try write(73, Int16(mtext.columnData.autoHeight ? 1 : 0))
        try write(74, Int16(mtext.columnData.flowReversed ? 1 : 0))
        for height in mtext.columnData.heights { try write(46, height) }
    }

    private func writeMultiLeader(_ leader: ACad.MultiLeader) throws {
        let context = leader.contextData
        try write(100, "AcDbMLeader")
        try write(270, Int32(2))
        try writeMultiLeaderAnnotContext(context)
        try writeHandle(340, leader.style)
        try write(90, leader.propertyOverrideFlags)
        try write(170, leader.pathType)
        try writeCmColor(91, leader.lineColor)
        // ACadSharp writes the entity's own line type here.
        try writeHandle(341, leader.lineType)
        try write(171, leader.leaderLineWeight.rawValue)
        try write(290, leader.enableLanding)
        try write(291, leader.enableDogleg)
        try write(41, leader.landingDistance)
        try write(42, leader.arrowheadSize)
        try write(172, leader.contentType)
        try writeHandle(343, leader.textStyle)
        try write(173, leader.textLeftAttachment)
        try write(95, leader.textRightAttachment)
        try write(174, leader.textAngle)
        try write(175, leader.textAlignment)
        try writeCmColor(92, leader.textColor)
        try write(292, leader.textFrame)
        try writeCmColor(93, leader.blockContentColor)
        try write(10, leader.blockContentScale)
        try write(43, leader.blockContentRotation)
        try write(176, leader.blockContentConnection)
        try write(293, leader.enableAnnotationScale)
        try write(294, leader.textDirectionNegative)
        try write(178, leader.textAligninIPE)
        try write(179, leader.textAttachmentPoint)
        try write(45, leader.scaleFactor)
        try write(271, leader.textAttachmentDirection)
        try write(272, leader.textBottomAttachment)
        try write(273, leader.textTopAttachment)
        try write(295, Int32(0))
    }

    private func writeMultiLeaderAnnotContext(_ context: ACad.MultiLeaderObjectContextData) throws {
        try write(300, "CONTEXT_DATA{")
        try write(40, context.scaleFactor)
        try write(10, context.contentBasePoint)
        try write(41, context.textHeight)
        try write(140, context.arrowheadSize)
        try write(145, context.landingGap)
        try write(174, context.textLeftAttachment)
        try write(175, context.textRightAttachment)
        try write(176, context.textAlignment)
        try write(177, context.blockContentConnection)
        try write(290, context.hasTextContents)
        try write(304, context.textLabel)
        try write(11, context.textNormal)
        try writeHandle(340, context.textStyle)
        try write(12, context.textLocation)
        try write(13, context.direction)
        try write(42, context.textRotation)
        try write(43, context.boundaryWidth)
        try write(44, context.boundaryHeight)
        try write(45, context.lineSpacingFactor)
        try write(170, context.lineSpacing)
        try writeCmColor(90, context.textColor)
        try write(171, context.textAttachmentPoint)
        try write(172, context.flowDirection)
        try writeCmColor(91, context.backgroundFillColor)
        try write(141, context.backgroundScaleFactor)
        try write(92, context.backgroundTransparency)
        try write(291, context.backgroundFillEnabled)
        try write(292, context.backgroundMaskFillOn)
        try write(173, context.columnType)
        try write(293, context.textHeightAutomatic)
        try write(142, context.columnWidth)
        try write(143, context.columnGutter)
        try write(294, context.columnFlowReversed)
        try write(295, context.wordBreak)
        try write(296, context.hasContentsBlock)
        try write(110, context.basePoint)
        try write(111, context.baseDirection)
        try write(112, context.baseVertical)
        try write(297, context.normalReversed)
        for root in context.leaderRoots {
            try write(302, "LEADER{")
            try write(290, Int16(1))
            try write(291, Int16(1))
            try write(10, root.connectionPoint)
            try write(11, root.direction)
            try write(90, root.leaderIndex)
            try write(40, root.landingDistance)
            for line in root.lines {
                try write(304, "LEADER_LINE{")
                for point in line.points { try write(10, point) }
                try write(91, line.index)
                try write(305, "}")
            }
            try write(271, Int32(0))
            try write(303, "}")
        }
        try write(272, context.textBottomAttachment)
        try write(273, context.textTopAttachment)
        try write(301, "}")
    }

    private func writePdfUnderlay(_ underlay: ACad.PdfUnderlay) throws {
        try write(100, ACad.DxfSubclassMarker.underlay)
        try writeHandle(340, underlay.definition)
        try write(10, underlay.insertPoint)
        try write(280, underlay.flags)
        try write(281, underlay.contrast)
        try write(282, underlay.fade)
        for vertex in underlay.clipBoundaryVertices { try write(11, vertex) }
    }

    private func writeOle2Frame(_ ole: ACad.Ole2Frame) throws {
        try write(100, ACad.DxfSubclassMarker.ole2Frame)
        try write(70, ole.version)
        try write(3, ole.sourceApplication)
        try write(10, ole.upperLeftCorner)
        try write(11, ole.lowerRightCorner)
        try write(71, ole.oleObjectType)
        try write(72, ole.isPaperSpace)
        try write(73, Int32(3))
        try write(90, Int32(ole.binaryData.count))
        try write(310, .bytes(ole.binaryData))
        try write(1, "OLE")
    }

    private func writePoint(_ point: ACad.Point) throws {
        try write(100, ACad.DxfSubclassMarker.point)
        try write(10, point.location)
        try write(39, point.thickness)
        try write(210, point.normal)
        try write(50, point.rotation, angle: true)
    }

    private func writePolyline(_ polyline: ACad.Polyline) throws {
        try write(100, polyline.subclassMarker)
        try write(10, Int32(0))
        try write(20, Int32(0))
        try write(30, polyline.elevation)
        try write(70, polyline.flags)
        try write(75, polyline.smoothSurface)
        if let mesh = polyline as? ACad.PolygonMesh {
            // ACadSharp writes the M count for both 71 and 72.
            try writeIfNotDefault(71, mesh.mVertexCount, 0)
            try writeIfNotDefault(72, mesh.mVertexCount, 0)
            try writeIfNotDefault(73, mesh.mSmoothSurfaceDensity, 0)
            try writeIfNotDefault(74, mesh.nSmoothSurfaceDensity, 0)
        } else if let mesh = polyline as? ACad.PolyfaceMesh {
            try writeIfNotDefault(71, Int32(mesh.vertices.count), 0)
            try writeIfNotDefault(72, Int32(mesh.faces.count), 0)
        }
        try write(210, polyline.normal)
        guard !polyline.vertices.isEmpty else { return }
        for vertex in polyline.vertices { try writeEntity(vertex) }
        if let mesh = polyline as? ACad.PolyfaceMesh {
            for face in mesh.faces { try writeEntity(face) }
        }
        try writeSeqend(polyline.vertices.seqend)
    }

    private func writeRay(_ ray: ACad.Ray) throws {
        try write(100, ACad.DxfSubclassMarker.ray)
        try write(10, ray.startPoint)
        try write(11, ray.direction)
    }

    /// `writeSeqend`.
    private func writeSeqend(_ seqend: ACad.Seqend?) throws {
        guard let seqend else { throw ACad.DxfWriteError.nullReference }
        try write(0, seqend.objectName)
        try write(5, .unsigned(seqend.handle))
        try write(330, .unsigned(seqend.ownerHandle))
        try write(100, ACad.DxfSubclassMarker.entity)
        try write(8, seqend.layer.name)
    }

    private func writeShape(_ shape: ACad.Shape) throws {
        try write(100, ACad.DxfSubclassMarker.shape)
        try write(39, shape.thickness)
        try write(10, shape.insertionPoint)
        try write(40, shape.size)
        try writeName(2, shape.shapeStyle?.name)
        try write(50, shape.rotation, angle: true)
        try write(41, shape.relativeXScale)
        try write(51, shape.obliqueAngle, angle: true)
        try write(210, shape.normal)
    }

    private func writeSolid(_ solid: ACad.Solid) throws {
        try write(100, ACad.DxfSubclassMarker.solid)
        try write(10, solid.firstCorner)
        try write(11, solid.secondCorner)
        try write(12, solid.thirdCorner)
        try write(13, solid.fourthCorner)
        try write(39, solid.thickness)
        try write(210, solid.normal)
    }

    private func writeSpline(_ spline: ACad.Spline) throws {
        try write(100, ACad.DxfSubclassMarker.spline)
        if spline.flags & ACad.SplineFlags.planar != 0 { try write(210, spline.normal) }
        try write(70, spline.flags)
        try write(71, Int16(truncatingIfNeeded: spline.degree))
        try write(72, Int16(truncatingIfNeeded: spline.knots.count))
        try write(73, Int16(truncatingIfNeeded: spline.controlPoints.count))
        if !spline.fitPoints.isEmpty { try write(74, Int16(truncatingIfNeeded: spline.fitPoints.count)) }
        try write(42, spline.knotTolerance)
        try write(43, spline.controlPointTolerance)
        try write(44, spline.fitTolerance)
        if !spline.startTangent.isNearZero { try write(12, spline.startTangent) }
        if !spline.endTangent.isNearZero { try write(13, spline.endTangent) }
        for knot in spline.knots { try write(40, knot) }
        for weight in spline.weights { try write(41, weight) }
        for point in spline.controlPoints { try write(10, point) }
        for point in spline.fitPoints { try write(11, point) }
    }

    private func writeTextEntity(_ text: ACad.TextEntity) throws {
        try write(100, ACad.DxfSubclassMarker.text)
        try write(1, text.value)
        try write(10, text.insertPoint)
        try write(40, text.height)
        if text.widthFactor != 1 { try write(41, text.widthFactor) }
        if text.rotation != 0 { try write(50, text.rotation, angle: true) }
        if text.obliqueAngle != 0 { try write(51, text.obliqueAngle, angle: true) }
        try write(7, text.style.name)
        try write(11, text.alignmentPoint)
        try write(210, text.normal)
        if text.mirror != 0 { try write(71, text.mirror) }
        if text.horizontalAlignment != 0 { try write(72, text.horizontalAlignment) }
        if type(of: text) == ACad.TextEntity.self {
            try write(100, ACad.DxfSubclassMarker.text)
            if text.verticalAlignment != 0 { try write(73, text.verticalAlignment) }
        }
        switch text {
        case let att as ACad.AttributeEntity:
            try write(100, ACad.DxfSubclassMarker.attribute)
            try writeAttributeBase(att)
        case let definition as ACad.AttributeDefinition:
            try write(100, ACad.DxfSubclassMarker.attributeDefinition)
            try write(3, definition.prompt)
            try writeAttributeBase(definition)
        default:
            break
        }
    }

    private func writeTolerance(_ tolerance: ACad.Tolerance) throws {
        try write(100, tolerance.subclassMarker)
        try writeName(3, tolerance.style.name)
        try write(10, tolerance.insertionPoint)
        try write(11, tolerance.direction)
        try write(210, tolerance.normal)
        try write(1, tolerance.text)
    }

    private func writeVertex(_ vertex: ACad.Vertex) throws {
        if !(vertex is ACad.VertexFaceRecord) { try write(100, ACad.DxfSubclassMarker.vertex) }
        try write(100, vertex.subclassMarker)
        try write(10, vertex.location)
        try writeIfNotDefault(40, vertex.startWidth, 0)
        try writeIfNotDefault(41, vertex.endWidth, 0)
        try writeIfNotDefault(42, vertex.bulge, 0)
        try write(70, vertex.flags)
        try write(50, vertex.curveTangent, angle: true)
        if let record = vertex as? ACad.VertexFaceRecord {
            try write(71, record.index1)
            try write(72, record.index2)
            try write(73, record.index3)
            try write(74, record.index4)
        }
    }

    private func writeViewport(_ vp: ACad.Viewport) throws {
        try write(100, ACad.DxfSubclassMarker.viewport)
        try write(10, vp.center)
        try write(40, vp.width)
        try write(41, vp.height)
        try write(68, vp.activeStatus)
        try write(69, vp.id)
        try write(12, vp.viewCenter)
        try write(13, vp.snapBase)
        try write(14, vp.snapSpacing)
        try write(15, vp.gridSpacing)
        try write(16, vp.viewDirection)
        try write(17, vp.viewTarget)
        try write(42, vp.lensLength)
        try write(43, vp.frontClipPlane)
        try write(44, vp.backClipPlane)
        try write(45, vp.viewHeight)
        try write(50, vp.snapAngle, angle: true)
        try write(51, vp.twistAngle, angle: true)
        try write(72, vp.circleZoomPercent)
        for layer in vp.frozenLayers { try write(331, .unsigned(layer.handle)) }
        try write(90, vp.status)
        if let boundary = vp.boundary { try write(340, .unsigned(boundary.handle)) }
        try write(110, vp.ucsOrigin)
        try write(111, vp.ucsXAxis)
        try write(112, vp.ucsYAxis)
    }

    private func writeXLine(_ xline: ACad.XLine) throws {
        try write(100, ACad.DxfSubclassMarker.xLine)
        try write(10, xline.firstPoint)
        try write(11, xline.direction)
    }
}
