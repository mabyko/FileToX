// Object groups of the DXF writer (ACadSharp 3.8.0 DxfObjectsSectionWriter): the objects reached from the root
// dictionary and the entities' extension dictionaries, in queue order.

import Foundation

extension ACad.DxfWriter {
    /// `writeObject`.
    func writeObject(_ object: ACad.CadObject) throws {
        guard try isObjectSupported(object) else { return }
        if object is E.XRecord, !writeXRecords { return }
        try write(0, object.objectName)
        try writeCommonObjectData(object)
        switch object {
        case is E.AcdbPlaceHolder: break
        case let data as E.BlockReferenceObjectContextData: try writeBlockReferenceObjectContextData(data)
        case let data as E.MTextAttributeObjectContextData: try writeMTextAttributeObjectContextData(data)
        case let color as E.BookColor: try writeBookColor(color)
        case let dictionary as E.CadDictionary: try writeDictionary(dictionary)
        case let data as E.BlockRepresentationData: try writeBlockRepresentationData(data)
        case let action as E.BlockMoveAction: try writeBlockMoveAction(action)
        case let action as E.BlockRotationAction: try writeBlockRotationAction(action)
        case let action as E.BlockStretchAction: try writeBlockStretchAction(action)
        case let action as E.BlockScaleAction: try writeBlockScaleAction(action)
        case let action as E.BlockLookupAction: try writeBlockLookupAction(action)
        case let action as E.BlockFlipAction: try writeBlockFlipAction(action)
        case let action as E.BlockArrayAction: try writeBlockArrayAction(action)
        case let action as E.BlockPolarStretchAction: try writeBlockPolarStretchAction(action)
        case let parameter as E.BlockRotationParameter: try writeBlockRotationParameter(parameter)
        case let parameter as E.BlockVisibilityParameter: try writeBlockVisibilityParameter(parameter)
        case let parameter as E.BlockLookupParameter: try writeBlockLookupParameter(parameter)
        case let parameter as E.BlockPointParameter: try writeBlockPointParameter(parameter)
        case let parameter as E.BlockAlignmentParameter: try writeBlockAlignmentParameter(parameter)
        case let parameter as E.BlockBasePointParameter: try writeBlockBasePointParameter(parameter)
        case let parameter as E.BlockFlipParameter: try writeBlockFlipParameter(parameter)
        case let parameter as E.BlockXYParameter: try writeBlockXYParameter(parameter)
        case let parameter as E.BlockPolarParameter: try writeBlockPolarParameter(parameter)
        case let variable as E.DictionaryVariable: try writeDictionaryVariable(variable)
        case let association as E.DimensionAssociation: try writeDimensionAssociation(association)
        case let preventer as E.DynamicBlockPurgePreventer:
            try write(100, ACad.DxfSubclassMarker.acDbDynamicBlockPurgePreventer)
            try write(70, preventer.version)
        case let geo as E.GeoData: try writeGeoData(geo)
        case let group as E.Group: try writeGroup(group)
        case let definition as E.ImageDefinition: try writeImageDefinition(definition)
        case let reactor as E.ImageDefinitionReactor:
            try write(100, ACad.DxfSubclassMarker.rasterImageDefReactor)
            try write(90, reactor.classVersion)
            try writeHandle(330, reactor.image)
        case let layout as E.Layout: try writeLayout(layout)
        case let graph as E.EvaluationGraph: try writeEvaluationGraph(graph)
        case let field as E.Field: try writeField(field)
        case let list as E.FieldList: try writeFieldList(list)
        case let style as E.MLineStyle: try writeMLineStyle(style)
        case let style as E.MultiLeaderStyle: try writeMultiLeaderStyle(style)
        case let component as E.BlockGripLocationComponent:
            try writeEvaluationExpression(component)
            try write(100, ACad.DxfSubclassMarker.blockGripExpression)
            try write(91, component.connection.id)
            try write(300, component.connection.name)
        case let grip as E.BlockXYGrip: try writeBlockGripBase(grip, ACad.DxfSubclassMarker.blockXYGrip)
        case let grip as E.BlockFlipGrip:
            try writeBlockGrip(grip)
            try write(100, ACad.DxfSubclassMarker.blockFlipGrip)
            try write(140, grip.directionX)
            try write(141, grip.directionY)
            try write(142, grip.directionZ)
            try write(93, grip.flipExpressionId)
        case let grip as E.BlockAlignmentGrip:
            try writeBlockGrip(grip)
            try write(100, ACad.DxfSubclassMarker.blockAlignmentGrip)
            try write(140, grip.alignmentX)
            try write(141, grip.alignmentY)
            try write(142, grip.alignmentZ)
        case let grip as E.BlockRotationGrip: try writeBlockGripBase(grip, ACad.DxfSubclassMarker.blockRotationGrip)
        case let grip as E.BlockLinearGrip:
            try writeBlockGrip(grip)
            try write(100, ACad.DxfSubclassMarker.blockLinearGrip)
            try write(140, grip.distanceX)
            try write(141, grip.distanceY)
            try write(142, grip.distanceZ)
        case let grip as E.BlockLookupGrip: try writeBlockGripBase(grip, ACad.DxfSubclassMarker.blockLookupGrip)
        case let grip as E.BlockVisibilityGrip: try writeBlockGripBase(grip, ACad.DxfSubclassMarker.blockVisibilityGrip)
        case let grip as E.BlockPolarGrip: try writeBlockGripBase(grip, ACad.DxfSubclassMarker.blockPolarGrip)
        case let parameter as E.BlockLinearParameter: try writeBlockLinearParameter(parameter)
        case let plot as E.PlotSettings: try writePlotSettings(plot)
        case let definition as E.PdfUnderlayDefinition:
            try write(100, ACad.DxfSubclassMarker.underlayDefinition)
            try write(1, definition.file)
            try write(2, definition.page)
        case let variables as E.RasterVariables:
            try write(100, ACad.DxfSubclassMarker.rasterVariables)
            try write(90, variables.classVersion)
            try write(70, Int32(variables.isDisplayFrameShown ? 1 : 0))
            try write(71, variables.displayQuality)
            try write(72, variables.displayQuality)
        case let scale as E.Scale:
            try write(100, ACad.DxfSubclassMarker.scale)
            try write(70, Int32(0))
            try write(300, scale.name)
            try write(140, scale.paperUnits)
            try write(141, scale.drawingUnits)
            try write(290, Int16(scale.isUnitScale ? 1 : 0))
        case let filter as E.SpatialFilter: try writeSpatialFilter(filter)
        case let table as E.SortEntitiesTable:
            try write(100, ACad.DxfSubclassMarker.sortentsTable)
            try writeHandle(330, table.blockOwner)
            for sorter in table.enumerate() {
                try writeHandle(331, sorter.entity)
                try write(5, .unsigned(sorter.sortHandle))
            }
        case let style as E.TableStyle: try writeTableStyle(style)
        case let variables as E.WipeoutVariables:
            try write(100, ACad.DxfSubclassMarker.wipeoutVariables)
            try write(70, Int32(variables.displayFrame ? 1 : 0))
        case let record as E.XRecord: try writeXRecord(record)
        default:
            throw ACad.DxfWriteError("Object not implemented : \(type(of: object))")
        }
        try writeExtendedData(object)
    }

    private func isObjectSupported(_ object: ACad.CadObject) throws -> Bool {
        guard try object.isValid(format: .dxf, version: version) else {
            notify("Invalid object \(type(of: object)) with handle \(object.handle)")
            return false
        }
        switch object {
        case is E.UnknownNonGraphicalObject, is E.UnmodelledObject:
            return false
        case is E.EvaluationGraph, is E.BlockRepresentationData, is E.DynamicBlockPurgePreventer:
            return writeDynamicBlockData
        case is E.AecWallStyle, is E.AecCleanupGroup, is E.DimensionAssociation, is E.Material, is E.MultiLeaderObjectContextData, is E.ProxyObject, is E.TableContent:
            notify("Object not implemented : \(type(of: object))")
            return false
        default:
            return true
        }
    }

    private func writeBookColor(_ color: ACad.BookColor) throws {
        try write(100, ACad.DxfSubclassMarker.dbColor)
        try write(62, color.color.approxIndex())
        try writeTrueColor(420, color.color)
        try write(430, "\(color.name)$\(color.bookName ?? "")")
    }

    private func writeDictionary(_ dictionary: ACad.CadDictionary) throws {
        try write(100, ACad.DxfSubclassMarker.dictionary)
        try write(280, dictionary.hardOwnerFlag)
        try write(281, Int32(dictionary.cloningFlags))
        for item in dictionary.values {
            if item is E.XRecord, !writeXRecords { continue }
            if item.name == ACad.CadDictionary.acadMaterial { continue }
            guard try isObjectSupported(item) else { continue }
            try write(3, item.name)
            try write(dictionary.hardOwnerFlag ? 360 : 350, .unsigned(item.handle))
            heldObjects.append(item)
        }
        if let withDefault = dictionary as? E.CadDictionaryWithDefault {
            try write(100, ACad.DxfSubclassMarker.dictionaryWithDefault)
            try writeHandle(340, withDefault.defaultEntry)
        }
    }

    private func writeDictionaryVariable(_ variable: ACad.DictionaryVariable) throws {
        try write(100, ACad.DxfSubclassMarker.dictionaryVariables)
        try write(1, variable.value)
        try write(280, variable.objectSchemaNumber)
    }

    private func writeGeoData(_ geo: ACad.GeoData) throws {
        try write(100, ACad.DxfSubclassMarker.geoData)
        switch version {
        case .ac1024: try write(90, Int32(2))
        case .ac1027, .ac1032: try write(90, Int32(3))
        default: try write(90, Int32(1))
        }
        if let host = geo.hostBlock { try write(330, .unsigned(host.handle)) }
        try write(70, geo.coordinatesType)
        let northAngle = Double.pi / 2 - geo.northDirection.angle
        if version <= .ac1021 {
            try write(40, geo.referencePoint.y)
            try write(41, geo.referencePoint.x)
            try write(42, geo.referencePoint.z)
            try write(91, geo.horizontalUnits)
            try write(10, geo.designPoint)
            try write(11, ACad.XYZ.zero)
            try write(210, geo.upDirection)
            try write(52, ACad.MathHelper.radToDeg(northAngle))
            try write(43, 1.0)
            try write(44, 1.0)
            try write(45, 1.0)
            try write(301, geo.coordinateSystemDefinition)
            try write(302, geo.geoRssTag)
            try write(46, geo.userSpecifiedScaleFactor)
            try write(303, "")
            try write(304, "")
            try write(305, geo.observationFromTag)
            try write(306, geo.observationToTag)
            try write(307, geo.observationCoverageTag)
            try write(93, Int32(geo.points.count))
            for point in geo.points {
                try write(12, point.source)
                try write(13, point.destination)
            }
            try write(96, Int32(geo.faces.count))
            for face in geo.faces {
                try write(97, face.index1)
                try write(98, face.index2)
                try write(99, face.index3)
            }
            try write(3, "CIVIL3D_DATA_BEGIN")
            try write(292, false)
            try write(14, geo.referencePoint.xy)
            try write(15, geo.referencePoint.xy)
            try write(93, Int32(0))
            try write(94, Int32(0))
            try write(293, false)
            try write(16, ACad.XY.zero)
            try write(17, ACad.XY.zero)
            try write(54, ACad.MathHelper.radToDeg(northAngle))
            try write(140, northAngle)
            try write(95, geo.scaleEstimationMethod)
            try write(141, geo.userSpecifiedScaleFactor)
            try write(294, geo.enableSeaLevelCorrection)
            try write(142, geo.seaLevelElevation)
            try write(143, geo.coordinateProjectionRadius)
            try write(4, "CIVIL3D_DATA_END")
        } else {
            try write(10, geo.designPoint)
            try write(11, geo.referencePoint)
            try write(40, geo.verticalUnitScale)
            try write(91, geo.horizontalUnits)
            try write(41, geo.verticalUnitScale)
            try write(92, geo.verticalUnits)
            try write(210, geo.upDirection)
            try write(12, geo.northDirection)
            try write(95, geo.scaleEstimationMethod)
            try write(141, geo.userSpecifiedScaleFactor)
            try write(294, geo.enableSeaLevelCorrection)
            try write(142, geo.seaLevelElevation)
            try write(143, geo.coordinateProjectionRadius)
            try writeLongTextValue(301, 303, geo.coordinateSystemDefinition)
            try write(302, geo.geoRssTag)
            try write(305, geo.observationFromTag)
            try write(306, geo.observationToTag)
            try write(307, geo.observationCoverageTag)
            try write(93, Int32(geo.points.count))
            for point in geo.points {
                try write(13, point.source)
                try write(14, point.destination)
            }
            try write(96, Int32(geo.faces.count))
            for face in geo.faces {
                try write(97, face.index1)
                try write(98, face.index2)
                try write(99, face.index3)
            }
        }
    }

    private func writeGroup(_ group: ACad.Group) throws {
        try write(100, ACad.DxfSubclassMarker.group)
        try write(300, group.description)
        try write(70, Int16(group.isUnnamed ? 1 : 0))
        try write(71, Int16(group.selectable ? 1 : 0))
        for entity in group.entities { try writeHandle(340, entity) }
    }

    private func writeImageDefinition(_ definition: ACad.ImageDefinition) throws {
        try write(100, ACad.DxfSubclassMarker.rasterImageDef)
        try write(90, definition.classVersion)
        try write(1, definition.fileName)
        try write(10, definition.size)
        try write(280, Int32(definition.isLoaded ? 1 : 0))
        try write(281, UInt8(truncatingIfNeeded: definition.units))
    }

    private func writeLayout(_ layout: ACad.Layout) throws {
        try writePlotSettings(layout)
        try write(100, ACad.DxfSubclassMarker.layout)
        try write(1, layout.name)
        try write(71, layout.tabOrder)
        try write(10, layout.minLimits)
        try write(11, layout.maxLimits)
        try write(12, layout.insertionBasePoint)
        try write(13, layout.origin)
        try write(14, layout.minExtents)
        try write(15, layout.maxExtents)
        try write(16, layout.xAxis)
        try write(17, layout.yAxis)
        try write(146, layout.elevation)
        try write(76, Int16(0))
        try writeHandle(330, layout.associatedBlock)
    }

    private func writeMLineStyle(_ style: ACad.MLineStyle) throws {
        try write(100, ACad.DxfSubclassMarker.mLineStyle)
        try write(2, style.name)
        try write(70, style.flags)
        try write(3, style.description)
        try write(62, style.fillColor.approxIndex())
        try write(51, style.startAngle, angle: true)
        try write(52, style.endAngle, angle: true)
        try write(71, Int16(truncatingIfNeeded: style.elements.count))
        for element in style.elements {
            try write(49, element.offset)
            try write(62, element.color.index)
            try write(6, element.lineType.name)
        }
    }

    private func writeMultiLeaderStyle(_ style: ACad.MultiLeaderStyle) throws {
        try write(100, ACad.DxfSubclassMarker.mLeaderStyle)
        try write(179, Int32(2))
        try write(170, style.contentType)
        try write(171, style.multiLeaderDrawOrder)
        try write(172, style.leaderDrawOrder)
        try write(90, style.maxLeaderSegmentsPoints)
        try write(40, style.firstSegmentAngleConstraint)
        try write(41, style.secondSegmentAngleConstraint)
        try write(173, style.pathType)
        try writeCmColor(91, style.lineColor)
        try writeHandle(340, style.leaderLineType)
        try write(92, style.leaderLineWeight.rawValue)
        try write(290, style.enableLanding)
        try write(42, style.landingGap)
        try write(291, style.enableDogleg)
        try write(43, style.landingDistance)
        try write(3, style.description)
        try writeHandle(341, style.arrowhead)
        try write(44, style.arrowheadSize)
        try write(300, style.defaultTextContents)
        try writeHandle(342, style.textStyle)
        try write(174, style.textLeftAttachment)
        try write(178, style.textRightAttachment)
        try write(175, style.textAngle)
        try write(176, style.textAlignment)
        try writeCmColor(93, style.textColor)
        try write(45, style.textHeight)
        try write(292, style.textFrame)
        try write(297, style.textAlignAlwaysLeft)
        try write(46, style.alignSpace)
        try writeHandle(343, style.blockContent)
        try writeCmColor(94, style.blockContentColor)
        try write(47, style.blockContentScale.x)
        try write(49, style.blockContentScale.y)
        try write(140, style.blockContentScale.z)
        try write(293, style.enableBlockContentScale)
        try write(141, style.blockContentRotation, angle: true)
        try write(294, style.enableBlockContentRotation)
        try write(177, style.blockContentConnection)
        try write(142, style.scaleFactor)
        try write(295, style.overwritePropertyValue)
        try write(296, style.isAnnotative)
        try write(143, style.breakGapSize)
        try write(271, style.textAttachmentDirection)
        try write(272, style.textBottomAttachment)
        try write(273, style.textTopAttachment)
        try write(298, false)
    }

    private func writePlotSettings(_ plot: ACad.PlotSettings) throws {
        try write(100, ACad.DxfSubclassMarker.plotSettings)
        try write(1, plot.pageName)
        try write(2, plot.systemPrinterName)
        try write(4, plot.paperSize)
        try write(6, plot.plotViewName)
        try write(7, plot.styleSheet)
        try write(40, plot.unprintableMargin.left)
        try write(41, plot.unprintableMargin.bottom)
        try write(42, plot.unprintableMargin.right)
        try write(43, plot.unprintableMargin.top)
        try write(44, plot.paperWidth)
        try write(45, plot.paperHeight)
        try write(46, plot.plotOriginX)
        try write(47, plot.plotOriginY)
        try write(48, plot.windowLowerLeftX)
        try write(49, plot.windowLowerLeftY)
        try write(140, plot.windowUpperLeftX)
        try write(141, plot.windowUpperLeftY)
        try write(142, plot.numeratorScale)
        try write(143, plot.denominatorScale)
        try write(70, plot.flags)
        try write(72, plot.paperUnits)
        try write(73, plot.paperRotation)
        try write(74, plot.plotType)
        try write(75, plot.scaledFit)
        try write(76, plot.shadePlotMode)
        try write(77, plot.shadePlotResolutionMode)
        try write(78, plot.shadePlotDPI)
        try write(147, plot.printScale)
        try write(148, plot.paperImageOriginX)
        try write(149, plot.paperImageOriginY)
    }

    private func writeSpatialFilter(_ filter: ACad.SpatialFilter) throws {
        try write(100, ACad.DxfSubclassMarker.filter)
        try write(100, ACad.DxfSubclassMarker.spatialFilter)
        try write(70, Int16(truncatingIfNeeded: filter.boundaryPoints.count))
        for point in filter.boundaryPoints { try write(10, point) }
        try write(210, filter.normal)
        try write(11, filter.origin)
        try write(71, Int16(filter.displayBoundary ? 1 : 0))
        try write(72, Int32(filter.clipFrontPlane ? 1 : 0))
        if filter.clipFrontPlane { try write(40, filter.frontDistance) }
        try write(73, Int32(filter.clipBackPlane ? 1 : 0))
        if filter.clipBackPlane { try write(41, filter.backDistance) }
        for value in filter.inverseInsertTransform.prefix(12) + filter.insertTransform.prefix(12) {
            try write(40, value)
        }
    }

    private func writeTableStyle(_ style: ACad.TableStyle) throws {
        try write(100, ACad.DxfSubclassMarker.tableStyle)
        try write(3, style.description)
        try write(70, style.flowDirection)
        try write(71, style.flags)
        try write(40, style.horizontalCellMargin)
        try write(41, style.verticalCellMargin)
        try write(280, Int32(style.suppressTitle ? 1 : 0))
        try write(281, Int32(style.suppressHeaderRow ? 1 : 0))
        try writeCellStyle(style.dataCellStyle)
        try writeCellStyle(style.titleCellStyle)
        try writeCellStyle(style.headerCellStyle)
    }

    private func writeCellStyle(_ style: ACad.TableStyle.CellStyle) throws {
        if let textStyle = style.textStyle {
            try write(7, textStyle.name)
        } else {
            try write(7, ACad.TextStyle.defaultName)
        }
        try write(140, style.textHeight)
        try write(170, style.cellAlignment)
        try write(62, style.contentColor.approxIndex())
        try write(63, style.backgroundColor.approxIndex())
        try write(283, Int32(style.isFillColorOn ? 1 : 0))
        try write(90, style.type)
        try write(91, style.valueDataType)
        for (i, border) in [style.topBorder, style.horizontalInsideBorder, style.bottomBorder, style.leftBorder,
                            style.verticalInsideBorder, style.rightBorder].enumerated() {
            try write(274 + i, border.lineWeight.rawValue)
            try write(284 + i, Int32(border.isInvisible ? 0 : 1))
            try write(64 + i, border.color.approxIndex())
        }
    }

    private func writeXRecord(_ record: ACad.XRecord) throws {
        try write(100, ACad.DxfSubclassMarker.xRecord)
        try write(280, record.cloningFlags)
        for entry in record.entries {
            switch ACad.GroupCodeValueType.of(entry.code) {
            case .none:
                break
            case .point3D:
                if case let .point(v) = entry.value { try write(entry.code, v) } else { try write(entry.code, entry.value.out) }
            case .handle, .objectId, .extendedDataHandle:
                guard case let .handle(handle) = entry.value else { throw ACad.DxfWriteError.nullReference }
                try write(entry.code, .unsigned(handle))
            default:
                try write(entry.code, entry.value.out)
            }
        }
    }

    // ───────────────────────── Dimension associativity ─────────────────────────

    private func writeDimensionAssociation(_ association: ACad.DimensionAssociation) throws {
        typealias F = ACad.DimensionAssociation.Flags
        try write(100, ACad.DxfSubclassMarker.dimensionAssociation)
        try writeHandle(330, association.dimension)
        try write(90, Int32(association.associativityFlags))
        try write(70, association.isTransSpace)
        try write(71, association.rotatedDimensionType)
        let flags = association.associativityFlags
        if flags & F.firstPointReference != 0 { try writeOsnapPointRef(association.firstPointRef) }
        if flags & F.secondPointReference != 0 { try writeOsnapPointRef(association.secondPointRef) }
        if flags & F.thirdPointReference != 0 { try writeOsnapPointRef(association.thirdPointRef) }
        if flags & F.fourthPointReference != 0 { try writeOsnapPointRef(association.fourthPointRef) }
    }

    private func writeOsnapPointRef(_ point: ACad.DimensionAssociation.OsnapPointRef?) throws {
        guard let point else { return }
        try write(1, ACad.DimensionAssociation.osnapPointRefClassName)
        try write(72, point.objectOsnapType)
        try writeHandle(331, point.geometry)
        try write(73, point.subentType)
        try write(91, point.gsMarker)
        try write(40, point.geometryParameter)
        try write(10, point.osnapPoint)
        try write(75, Int16(point.hasLastPointRef ? 1 : 0))
    }

    // ───────────────────────── Context data ─────────────────────────

    private func writeAnnotScaleObjectContextData(_ data: ACad.AnnotScaleObjectContextData) throws {
        try write(100, ACad.DxfSubclassMarker.annotScaleObjectContextData)
        try writeHandle(340, data.scale)
    }

    private func writeBlockReferenceObjectContextData(_ data: ACad.BlockReferenceObjectContextData) throws {
        try writeAnnotScaleObjectContextData(data)
        try write(50, data.rotation, angle: true)
        try write(10, data.insertionPoint)
        try write(41, data.xScale)
        try write(42, data.yScale)
        try write(43, data.zScale)
    }

    private func writeMTextAttributeObjectContextData(_ data: ACad.MTextAttributeObjectContextData) throws {
        try writeAnnotScaleObjectContextData(data)
        try write(70, data.attachmentPoint)
        try write(50, data.rotation, angle: true)
        try write(10, data.alignmentPoint)
        try write(11, data.insertPoint)
        try write(290, data.value290)
    }

    // ───────────────────────── Fields ─────────────────────────

    private func writeField(_ field: ACad.Field) throws {
        try write(100, ACad.DxfSubclassMarker.field)
        try write(1, field.evaluatorId)
        try writeLongTextValue(2, 3, field.fieldCode)
        try write(90, Int32(field.children.count))
        for child in field.children { try writeHandle(360, child) }
        try write(97, Int32(field.cadObjects.count))
        for object in field.cadObjects { try writeHandle(331, object) }
        try write(91, field.evaluationOptionFlags)
        try write(92, field.filingOptionFlags)
        try write(94, field.fieldStateFlags)
        try write(95, field.evaluationStatusFlags)
        try write(96, field.evaluationErrorCode)
        try write(300, field.evaluationErrorMessage)
        try write(93, Int32(field.values.count))
        for (key, value) in field.values.pairs {
            try write(6, key)
            try writeCadValue(value)
        }
        try write(7, "ACFD_FIELD_VALUE")
        try writeCadValue(field.value)
        try writeLongTextValue(301, 9, field.formatString)
        guard let format = field.formatString else { throw ACad.DxfWriteError.nullReference }
        try write(98, Int32(format.utf16.count))
    }

    private func writeFieldList(_ list: ACad.FieldList) throws {
        try write(100, ACad.DxfSubclassMarker.idSet)
        try write(90, Int32(list.fields.count))
        for field in list.fields {
            try writeHandle(330, field)
            heldObjects.append(field)
        }
        try write(100, ACad.DxfSubclassMarker.fieldList)
    }

    // ───────────────────────── Dynamic blocks ─────────────────────────

    private func writeEvaluationExpression(_ expression: ACad.EvaluationExpression) throws {
        try write(100, ACad.DxfSubclassMarker.evalGraphExpr)
        try write(90, expression.id)
        try write(98, expression.value98)
        try write(99, expression.value99)
        if let pair = expression.evaluatedValue {
            try write(1, "")
            try write(70, Int32(pair.code))
            try write(pair.code, pair.value.out)
        }
    }

    private func writeBlockElement(_ element: ACad.BlockElement) throws {
        try writeEvaluationExpression(element)
        try write(100, ACad.DxfSubclassMarker.blockElement)
        try write(300, element.elementName)
        try write(98, Int32(33))
        try write(99, Int32(329))
        try write(1071, element.value1071)
    }

    private func writeBlockParameter(_ parameter: ACad.BlockParameter) throws {
        try writeBlockElement(parameter)
        try write(100, ACad.DxfSubclassMarker.blockParameter)
        try write(280, UInt8(parameter.showProperties ? 1 : 0))
        try write(281, UInt8(parameter.chainActions ? 1 : 0))
    }

    private func writeEvalParameterProperty(_ property: ACad.EvalParameterProperty, _ countCode: Int, _ idCode: Int, _ nameCode: Int) throws {
        try write(countCode, Int16(truncatingIfNeeded: property.connections.count))
        for connection in property.connections {
            try write(idCode, connection.id)
            try write(nameCode, connection.name)
        }
    }

    private func writeEvalConnection(_ connection: ACad.EvalConnection?, _ idCode: Int, _ nameCode: Int, reversed: Bool = false) throws {
        guard let connection else { throw ACad.DxfWriteError.nullReference }
        if reversed {
            try write(nameCode, connection.name)
            try write(idCode, connection.id)
        } else {
            try write(idCode, connection.id)
            try write(nameCode, connection.name)
        }
    }

    private func writeBlock1PtParameter(_ parameter: ACad.Block1PtParameter) throws {
        try writeBlockParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.block1PtParameter)
        try write(1010, parameter.location)
        try write(93, parameter.gripId)
        try writeEvalParameterProperty(parameter.displacementX, 170, 91, 301)
        try writeEvalParameterProperty(parameter.displacementY, 171, 92, 302)
    }

    private func writeBlock2PtParameter(_ parameter: ACad.Block2PtParameter) throws {
        try writeBlockParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.block2PtParameter)
        try write(1010, parameter.firstPoint)
        try write(1011, parameter.secondPoint)
        try write(170, Int16(4))
        for id in parameter.gripIds { try write(91, id) }
        for (i, property) in [parameter.firstPointDisplacementX, parameter.firstPointDisplacementY,
                              parameter.secondPointDisplacementX, parameter.secondPointDisplacementY].enumerated() {
            try writeEvalParameterProperty(property, 171 + i, 92 + i, 301 + i)
        }
        try write(177, Int16(truncatingIfNeeded: parameter.baseLocation))
    }

    private func writeBlockAction(_ action: ACad.BlockAction) throws {
        try writeBlockElement(action)
        try write(100, ACad.DxfSubclassMarker.blockAction)
        try write(70, Int16(truncatingIfNeeded: action.parametersIds.count))
        for id in action.parametersIds { try write(91, id) }
        try write(71, Int16(truncatingIfNeeded: action.entities.count))
        for entity in action.entities { try writeHandle(330, entity) }
        try write(1010, action.labelPosition)
    }

    private func writeBlockActionBasePt(_ action: ACad.BlockActionBasePt) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockActionBasePt)
        try write(92, action.updateBaseXConnection.id)
        try write(93, action.updateBaseYConnection.id)
        try write(301, action.updateBaseXConnection.name)
        try write(302, action.updateBaseYConnection.name)
        try write(1011, action.basePoint)
        try write(280, Int16(action.value280 ? 1 : 0))
        try write(1012, action.value1012)
    }

    private func writeBlockGrip(_ grip: ACad.BlockGrip) throws {
        try writeBlockElement(grip)
        try write(100, ACad.DxfSubclassMarker.blockGrip)
        try write(91, grip.expressionId1)
        try write(92, grip.expressionId2)
        try write(1010, grip.location)
        try write(280, Int16(grip.cycling ? 1 : 0))
        try write(93, grip.value93)
    }

    private func writeBlockGripBase(_ grip: ACad.BlockGrip, _ subclass: String) throws {
        try writeBlockGrip(grip)
        try write(100, subclass)
    }

    private func writeBlockAlignmentParameter(_ parameter: ACad.BlockAlignmentParameter) throws {
        try writeBlock2PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockAlignmentParameter)
        try write(280, UInt8(parameter.isPerpendicular ? 1 : 0))
    }

    private func writeBlockArrayAction(_ action: ACad.BlockArrayAction) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockArrayAction)
        try write(92, action.baseConnection.id)
        try write(93, action.endConnection.id)
        try write(94, action.updatedBaseConnection.id)
        try write(95, action.updatedEndConnection.id)
        try write(301, action.baseConnection.name)
        try write(302, action.endConnection.name)
        try write(303, action.updatedBaseConnection.name)
        try write(304, action.updatedEndConnection.name)
        try write(140, action.rowOffset)
        try write(141, action.columnOffset)
    }

    private func writeBlockBasePointParameter(_ parameter: ACad.BlockBasePointParameter) throws {
        try writeBlock1PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockBasePointParameter)
        try write(1011, parameter.point1011)
        try write(1012, parameter.point1012)
    }

    private func writeBlockFlipAction(_ action: ACad.BlockFlipAction) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockFlipAction)
        try write(92, action.flipConnection.id)
        try write(93, action.updatedFlipConnection.id)
        try write(94, action.updatedBaseConnection.id)
        try write(95, action.updatedEndConnection.id)
        try write(301, action.flipConnection.name)
        try write(302, action.updatedFlipConnection.name)
        try write(303, action.updatedBaseConnection.name)
        try write(304, action.updatedEndConnection.name)
    }

    private func writeBlockFlipParameter(_ parameter: ACad.BlockFlipParameter) throws {
        try writeBlock2PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockFlipParameter)
        try write(305, parameter.label)
        try write(306, parameter.description)
        try write(307, parameter.baseStateName)
        try write(308, parameter.flippedStateName)
        try write(1012, parameter.labelPosition)
        try writeEvalConnection(parameter.updatedFlipConnection, 96, 309, reversed: true)
    }

    private func writeBlockLinearParameter(_ parameter: ACad.BlockLinearParameter) throws {
        try writeBlock2PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockLinearParameter)
        try write(305, parameter.label)
        try write(306, parameter.description)
        try write(140, parameter.labelOffset)
        try writeParameterValueSet(parameter.valueSet, 307, 96, 141, 175)
    }

    private func writeBlockLookupAction(_ action: ACad.BlockLookupAction) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockLookupAction)
        let rows = action.columns.first?.rows.count ?? 0
        let columns = action.columns.count
        try write(92, Int32(rows))
        try write(93, Int32(columns))
        try write(301, "")
        for i in 0..<rows {
            for j in 0..<columns {
                guard i < action.columns[j].rows.count else {
                    throw ACad.DxfWriteError("Index was out of range. Must be non-negative and less than the size of the collection. (Parameter 'index')")
                }
                try write(302, action.columns[j].rows[i])
            }
        }
        for column in action.columns {
            try write(303, "")
            try write(94, column.nodeId)
            try write(95, column.valueType)
            try write(96, column.type)
            try write(282, UInt8(column.isLookupProperty ? 1 : 0))
            try write(305, column.unmatchedName)
            try write(281, UInt8(column.isReadOnly ? 0 : 1))
            try write(304, column.connectionName)
        }
        try write(280, UInt8(action.unknownFlag ? 1 : 0))
    }

    private func writeBlockLookupParameter(_ parameter: ACad.BlockLookupParameter) throws {
        try writeBlock1PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockLookupParameter)
        try write(303, parameter.label)
        try write(304, parameter.description)
        try write(94, parameter.actionId)
    }

    private func writeBlockMoveAction(_ action: ACad.BlockMoveAction) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockMoveAction)
        try writeEvalConnection(action.xDeltaConnection, 92, 301)
        try writeEvalConnection(action.yDeltaConnection, 93, 302)
        try write(140, action.distanceMultiplier)
        try write(141, action.angleOffset)
        try write(280, action.unknownFlag)
    }

    private func writeBlockPointParameter(_ parameter: ACad.BlockPointParameter) throws {
        try writeBlock1PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockPointParameter)
        try write(303, parameter.label)
        try write(304, parameter.description)
        try write(1011, parameter.labelPosition)
    }

    private func writeBlockPolarParameter(_ parameter: ACad.BlockPolarParameter) throws {
        try writeBlock2PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockPolarParameter)
        try write(305, parameter.label)
        try write(306, parameter.description)
        try write(307, parameter.angleName)
        try write(308, parameter.angleDescription)
        try write(140, parameter.labelOffset)
        try writeParameterValueSet(parameter.distanceValueSet, 309, 96, 141, 175)
        try writeParameterValueSet(parameter.angleValueSet, 410, 97, 145, 176)
    }

    private func writeBlockPolarStretchAction(_ action: ACad.BlockPolarStretchAction) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockPolarStretchAction)
        try writeEvalConnection(action.baseXDeltaConnection, 92, 301)
        try writeEvalConnection(action.baseYDeltaConnection, 93, 302)
        try writeEvalConnection(action.baseConnection, 94, 303)
        try writeEvalConnection(action.endConnection, 95, 304)
        try writeEvalConnection(action.updatedBaseConnection, 96, 305)
        try writeEvalConnection(action.updatedEndConnection, 97, 306)
        try write(73, Int32(action.boundary.count))
        for point in action.boundary { try write(1011, point) }
        try write(72, Int32(action.rotateBindings.count))
        for entity in action.rotateBindings { try writeHandle(331, entity) }
        try write(74, Int32(action.stretchBindings.count))
        for binding in action.stretchBindings {
            try writeHandle(332, binding.entity)
            try write(75, Int32(binding.pointIndexes.count))
            for index in binding.pointIndexes { try write(76, index) }
        }
        try write(78, Int32(action.stretchNodes.count))
        for node in action.stretchNodes {
            try write(98, node.nodeId)
            try write(79, Int32(node.pointIndexes.count))
            for index in node.pointIndexes { try write(76, index) }
        }
        try write(141, action.distanceMultiplier)
        try write(140, action.angleOffset)
        try write(77, Int32(0))
    }

    private func writeBlockRepresentationData(_ data: ACad.BlockRepresentationData) throws {
        try write(100, ACad.DxfSubclassMarker.blockRepresentationData)
        try write(70, data.version)
        try writeHandle(340, data.block)
    }

    private func writeBlockRotationAction(_ action: ACad.BlockRotationAction) throws {
        try writeBlockActionBasePt(action)
        try write(100, ACad.DxfSubclassMarker.blockRotationAction)
        try writeEvalConnection(action.angleDeltaConnection, 94, 303)
    }

    private func writeBlockRotationParameter(_ parameter: ACad.BlockRotationParameter) throws {
        try writeBlock2PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockRotationParameter)
        try write(305, parameter.label)
        try write(306, parameter.description)
        try write(1011, parameter.point)
        try write(140, parameter.labelOffset)
        try writeParameterValueSet(parameter.valueSet, 307, 96, 141, 175)
    }

    private func writeBlockScaleAction(_ action: ACad.BlockScaleAction) throws {
        try writeBlockActionBasePt(action)
        try write(100, ACad.DxfSubclassMarker.blockScaleAction)
        try write(94, action.scaleConnection.id)
        try write(95, action.xScaleConnection.id)
        try write(96, action.yScaleConnection.id)
        try write(303, action.scaleConnection.name)
        try write(304, action.xScaleConnection.name)
        try write(305, action.yScaleConnection.name)
    }

    private func writeBlockStretchAction(_ action: ACad.BlockStretchAction) throws {
        try writeBlockAction(action)
        try write(100, ACad.DxfSubclassMarker.blockStretchAction)
        try writeEvalConnection(action.endXDeltaConnection, 92, 301)
        try writeEvalConnection(action.endYDeltaConnection, 93, 302)
        try write(72, Int32(action.boundary.count))
        for point in action.boundary { try write(1011, point) }
        try write(73, Int32(action.stretchBindings.count))
        for binding in action.stretchBindings {
            try writeHandle(331, binding.entity)
            try write(74, Int32(binding.pointIndexes.count))
            for index in binding.pointIndexes { try write(94, index) }
        }
        try write(75, Int32(action.stretchNodes.count))
        for node in action.stretchNodes {
            try write(95, node.nodeId)
            try write(76, Int32(node.pointIndexes.count))
            for index in node.pointIndexes { try write(94, index) }
        }
        try write(140, action.distanceMultiplier)
        try write(141, action.angleOffset)
        try write(280, action.unknownFlag)
    }

    private func writeBlockVisibilityParameter(_ parameter: ACad.BlockVisibilityParameter) throws {
        try writeBlock1PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockVisibilityParameter)
        try write(281, UInt8(parameter.value281 ? 1 : 0))
        try write(301, parameter.label)
        try write(302, parameter.description)
        try write(91, Int32(parameter.value91 ? 1 : 0))
        try write(93, Int32(parameter.entities.count))
        for entity in parameter.entities { try writeHandle(331, entity) }
        try write(92, Int32(parameter.states.count))
        for state in parameter.states.values {
            try write(303, state.name)
            try write(94, Int32(state.entities.count))
            for entity in state.entities { try writeHandle(332, entity) }
            try write(95, Int32(state.expressions.count))
            for expression in state.expressions { try writeHandle(333, expression) }
        }
    }

    private func writeBlockXYParameter(_ parameter: ACad.BlockXYParameter) throws {
        try writeBlock2PtParameter(parameter)
        try write(100, ACad.DxfSubclassMarker.blockXYParameter)
        try write(305, parameter.labelY)
        try write(306, parameter.labelX)
        try write(307, parameter.descriptionY)
        try write(308, parameter.descriptionX)
        try write(140, parameter.labelOffsetY)
        try write(141, parameter.labelOffsetX)
        try writeParameterValueSet(parameter.valueSetY, 309, 97, 146, 176)
        try writeParameterValueSet(parameter.valueSetX, 410, 96, 142, 175)
    }

    private func writeParameterValueSet(_ set: ACad.ParameterValueSet?, _ startCode: Int, _ typeCode: Int, _ valueCode: Int,
                                        _ countCode: Int) throws {
        guard let set else { throw ACad.DxfWriteError.nullReference }
        try write(startCode, "")
        try write(typeCode, set.type)
        try write(valueCode, set.minimum)
        try write(valueCode + 1, set.maximum)
        try write(valueCode + 2, set.increment)
        try write(countCode, Int32(set.allowedValues.count))
        for value in set.allowedValues { try write(valueCode + 3, value) }
    }

    private func writeEvaluationGraph(_ graph: ACad.EvaluationGraph) throws {
        try write(100, ACad.DxfSubclassMarker.evalGraph)
        try write(96, graph.value96)
        try write(97, graph.value97)
        for (i, node) in graph.nodes.enumerated() {
            try write(91, Int32(i))
            try write(93, node.flags)
            try write(95, node.id)
            try writeHandle(360, node.expression)
            try write(92, node.data1)
            try write(92, node.data2)
            try write(92, node.data3)
            try write(92, node.data4)
            if let expression = node.expression { heldObjects.append(expression) }
        }
        for (i, edge) in graph.edges.enumerated() {
            try write(92, Int32(i))
            try write(93, edge.flags)
            try write(94, edge.trackedCount)
            try write(91, edge.fromNodeIndex)
            try write(91, edge.toNodeIndex)
            try write(92, edge.data1)
            try write(92, edge.data2)
            try write(92, edge.data3)
            try write(92, edge.data4)
            try write(92, edge.data5)
        }
    }
}

extension ACad.DxfValue {
    /// The boxed value of an xrecord or evaluated value entry.
    var out: ACad.DxfOut {
        switch self {
        case let .string(s): return .string(s)
        case let .double(d): return .double(d)
        case let .int16(v): return .integer(Int64(v))
        case let .int32(v): return .integer(Int64(v))
        case let .int64(v): return .integer(v)
        case let .byte(v): return .integer(Int64(v))
        case let .bool(b): return .bool(b)
        case let .point(p): return .double(p.x)
        case let .handle(h): return .unsigned(h)
        case let .bytes(d): return .bytes(d)
        }
    }
}
