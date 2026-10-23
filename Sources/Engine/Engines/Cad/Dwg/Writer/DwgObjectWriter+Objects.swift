// Non-graphical object records of the DWG object writer (ACadSharp 3.8.0 DwgObjectWriter.Objects), AC1032
// branches.

import Foundation

extension ACad.DwgObjectWriter {
    private func addObjectsToWriter<S: Sequence>(_ entries: S) where S.Element: ACad.NonGraphicalObject {
        for e in entries { enqueueValidObject(e) }
    }

    /// `skipEntry`: invalid objects are reported but still written, as in ACadSharp.
    private func skipEntry(_ entry: ACad.NonGraphicalObject, _ notify: inout Bool) throws -> Bool {
        guard try entry.isValid(format: .dwg, version: version) else {
            notify = false
            note("Invalid object \(type(of: entry)) with handle \(entry.handle)")
            return false
        }
        notify = true
        switch entry {
        case is ACad.EvaluationGraph where !writeDynamicParameters,
             is ACad.BlockRepresentationData where !writeDynamicParameters,
             is ACad.DynamicBlockPurgePreventer where !writeDynamicParameters,
             is ACad.XRecord where !writeXRecords:
            notify = false
            return true
        case is ACad.DimensionAssociation, is ACad.UnknownNonGraphicalObject, is ACad.ProxyObject, is ACad.UnmodelledObject:
            // `AecWallStyle`, `AecCleanupGroup`, `AecBinRecord` and `VisualStyle` are unmodelled objects here.
            return true
        default:
            return false
        }
    }

    private func skipEntry(_ entry: ACad.NonGraphicalObject) throws -> Bool {
        var notify = false
        return try skipEntry(entry, &notify)
    }

    /// `writeObject`.
    func writeObject(_ object: ACad.NonGraphicalObject) throws {
        var notify = false
        if try skipEntry(object, &notify) {
            if notify { note("Object type not implemented \(type(of: object))") }
            return
        }
        try writeCommonNonEntityData(object)
        switch object {
        case is ACad.AcdbPlaceHolder: break
        case let p as ACad.BlockLinearParameter: writeBlockLinearParameter(p)
        case let p as ACad.BlockRotationParameter: writeBlockRotationParameter(p)
        case let p as ACad.BlockPointParameter: writeBlockPointParameter(p)
        case let p as ACad.BlockVisibilityParameter: writeBlockVisibilityParameter(p)
        case let p as ACad.BlockLookupParameter: writeBlockLookupParameter(p)
        case let p as ACad.BlockAlignmentParameter: writeBlockAlignmentParameter(p)
        case let p as ACad.BlockBasePointParameter: writeBlockBasePointParameter(p)
        case let p as ACad.BlockFlipParameter: writeBlockFlipParameter(p)
        case let p as ACad.BlockXYParameter: writeBlockXYParameter(p)
        case let p as ACad.BlockPolarParameter: writeBlockPolarParameter(p)
        case let g as ACad.BlockVisibilityGrip: writeBlockGrip(g)
        case let r as ACad.BlockRepresentationData:
            writer.writeBitShort(r.version)
            writer.handleReference(.hardPointer, r.block?.handle ?? 0)
        case let g as ACad.BlockAlignmentGrip:
            writeBlockGrip(g)
            writer.writeBitDouble(g.alignmentX)
            writer.writeBitDouble(g.alignmentY)
            writer.writeBitDouble(g.alignmentZ)
        case let g as ACad.BlockFlipGrip:
            writeBlockGrip(g)
            writer.writeBitLong(g.flipExpressionId)
            writer.writeBitDouble(g.directionX)
            writer.writeBitDouble(g.directionY)
            writer.writeBitDouble(g.directionZ)
        case let g as ACad.BlockPolarGrip: writeBlockGrip(g)
        case let g as ACad.BlockLinearGrip:
            writeBlockGrip(g)
            writer.writeBitDouble(g.distanceX)
            writer.writeBitDouble(g.distanceY)
            writer.writeBitDouble(g.distanceZ)
        case let g as ACad.BlockRotationGrip: writeBlockGrip(g)
        case let g as ACad.BlockXYGrip: writeBlockGrip(g)
        case let g as ACad.BlockLookupGrip: writeBlockGrip(g)
        case let g as ACad.BlockGripLocationComponent:
            writeEvaluationExpression(g)
            writeEvalConnection(g.connection)
        case let a as ACad.BlockPolarStretchAction: writeBlockPolarStretchAction(a)
        case let a as ACad.BlockFlipAction:
            writeBlockAction(a)
            writeEvalConnection(a.flipConnection)
            writeEvalConnection(a.updatedFlipConnection)
            writeEvalConnection(a.updatedBaseConnection)
            writeEvalConnection(a.updatedEndConnection)
        case let a as ACad.BlockArrayAction:
            writeBlockAction(a)
            writeEvalConnection(a.baseConnection)
            writeEvalConnection(a.endConnection)
            writeEvalConnection(a.updatedBaseConnection)
            writeEvalConnection(a.updatedEndConnection)
            writer.writeBitDouble(a.rowOffset)
            writer.writeBitDouble(a.columnOffset)
        case let a as ACad.BlockScaleAction:
            writeBlockActionBasePt(a)
            writeEvalConnection(a.scaleConnection)
            writeEvalConnection(a.xScaleConnection)
            writeEvalConnection(a.yScaleConnection)
            writer.writeByte(a.scaleType)
        case let a as ACad.BlockRotationAction:
            writeBlockActionBasePt(a)
            writeEvalConnection(a.angleDeltaConnection)
        case let a as ACad.BlockMoveAction:
            writeBlockAction(a)
            writeEvalConnection(a.xDeltaConnection)
            writeEvalConnection(a.yDeltaConnection)
            writer.writeBitDouble(a.distanceMultiplier)
            writer.writeBitDouble(a.angleOffset)
            writer.writeByte(a.unknownFlag)
        case let a as ACad.BlockStretchAction: writeBlockStretchAction(a)
        case let a as ACad.BlockLookupAction: writeBlockLookupAction(a)
        case let color as ACad.BookColor: writeBookColor(color)
        case let data as ACad.BlockReferenceObjectContextData:
            writeAnnotScaleObjectContextData(data)
            writer.writeBitDouble(data.rotation)
            writer.write3BitDouble(data.insertionPoint)
            writer.writeBitDouble(data.xScale)
            writer.writeBitDouble(data.yScale)
            writer.writeBitDouble(data.zScale)
        case let dictionary as ACad.CadDictionaryWithDefault:
            try writeDictionary(dictionary)
            writer.handleReference(.hardPointer, dictionary.defaultEntry?.handle ?? 0)
        case let dictionary as ACad.CadDictionary: try writeDictionary(dictionary)
        case let variable as ACad.DictionaryVariable:
            writer.writeByte(0)
            writer.writeVariableText(variable.value)
        case let association as ACad.DimensionAssociation: writeDimensionAssociation(association)
        case let purge as ACad.DynamicBlockPurgePreventer:
            writer.writeBitShort(purge.version)
            writer.handleReference(.hardPointer, purge.block?.handle ?? 0)
        case let graph as ACad.EvaluationGraph: writeEvaluationGraph(graph)
        case let geo as ACad.GeoData: writeGeoData(geo)
        case let group as ACad.Group:
            writer.writeVariableText(group.description)
            writer.writeBitShort(group.isUnnamed ? 1 : 0)
            writer.writeBitShort(group.selectable ? 1 : 0)
            writer.writeBitLong(Int32(group.entities.count))
            for e in group.entities { writer.handleReference(.hardPointer, e.handle) }
        case let reactor as ACad.ImageDefinitionReactor: writer.writeBitLong(reactor.classVersion)
        case let definition as ACad.ImageDefinition:
            writer.writeBitLong(definition.classVersion)
            writer.write2RawDouble(definition.size)
            writer.writeVariableText(definition.fileName)
            writer.writeBit(definition.isLoaded)
            writer.writeByte(definition.units)
            writer.write2RawDouble(definition.defaultSize)
        case let layout as ACad.Layout: writeLayout(layout)
        case let material as ACad.Material: writeMaterial(material)
        case let style as ACad.MLineStyle: writeMLineStyle(style)
        case let style as ACad.MultiLeaderStyle: writeMultiLeaderStyle(style)
        case let context as ACad.MultiLeaderObjectContextData:
            writeAnnotScaleObjectContextData(context)
            writeMultiLeaderAnnotContextSubObject(false, context)
        case let definition as ACad.PdfUnderlayDefinition:
            writer.writeVariableText(definition.file)
            writer.writeVariableText(definition.page)
        case let plot as ACad.PlotSettings: writePlotSettings(plot)
        case let variables as ACad.RasterVariables:
            writer.writeBitLong(variables.classVersion)
            writer.writeBitShort(variables.isDisplayFrameShown ? 1 : 0)
            writer.writeBitShort(variables.displayQuality)
            writer.writeBitShort(variables.units)
        case let scale as ACad.Scale:
            writer.writeBitShort(0)
            writer.writeVariableText(scale.name)
            writer.writeBitDouble(scale.paperUnits)
            writer.writeBitDouble(scale.drawingUnits)
            writer.writeBit(scale.isUnitScale)
        case let table as ACad.SortEntitiesTable:
            writer.handleReference(.softPointer, table.blockOwner?.handle ?? 0)
            // `Count()` and `foreach` each enumerate, and every enumeration sorts the list in place.
            writer.writeBitLong(Int32(table.enumerate().count))
            for item in table.enumerate() {
                writer.main.handleReference(.undefined, item.sortHandle)
                writer.handleReference(.softPointer, item.entity.handle)
            }
        case let filter as ACad.SpatialFilter: writeSpatialFilter(filter)
        case let style as ACad.TableStyle: try writeTableStyle(style)
        case is ACad.MTextAttributeObjectContextData:
            throw ACad.DwgError.notImplemented
        case let variables as ACad.WipeoutVariables:
            writer.writeBitShort(variables.displayFrame ? 1 : 0)
        case let field as ACad.Field: try writeField(field)
        case let list as ACad.FieldList:
            writer.writeBitLong(Int32(list.fields.count))
            writer.writeBit(true)
            for field in list.fields { writer.handleReference(.softPointer, field.handle) }
        case let record as ACad.XRecord: try writeXRecord(record)
        default:
            throw ACad.DwgError("Object not implemented : \(type(of: object))")
        }
        try registerObject(object)
    }

    // ───────────────────────── Dynamic blocks ─────────────────────────

    private func writeAnnotScaleObjectContextData(_ data: ACad.AnnotScaleObjectContextData) {
        writer.writeBitShort(data.version)
        writer.writeBit(data.hasFileToExtensionDictionary)
        writer.writeBit(data.default)
        writer.handleReference(.hardPointer, data.scale.handle)
    }

    private func writeBlock1PtParameter(_ p: ACad.Block1PtParameter) {
        writeBlockParameter(p)
        writer.write3BitDouble(p.location)
        writeEvalParameterProperty(p.displacementX)
        writeEvalParameterProperty(p.displacementY)
        writer.writeBitLong(Int32(truncatingIfNeeded: p.gripId))
    }

    private func writeBlock2PtParameter(_ p: ACad.Block2PtParameter) {
        writeBlockParameter(p)
        writer.write3BitDouble(p.firstPoint)
        writer.write3BitDouble(p.secondPoint)
        writeEvalParameterProperty(p.firstPointDisplacementX)
        writeEvalParameterProperty(p.firstPointDisplacementY)
        writeEvalParameterProperty(p.secondPointDisplacementX)
        writeEvalParameterProperty(p.secondPointDisplacementY)
        for id in p.gripIds { writer.writeBitLong(Int32(truncatingIfNeeded: id)) }
        writer.writeBitShort(Int16(truncatingIfNeeded: p.baseLocation))
    }

    private func writeBlockAction(_ action: ACad.BlockAction) {
        writeBlockElement(action)
        writer.write3BitDouble(action.labelPosition)
        writer.writeBitLong(Int32(action.entities.count))
        for entity in action.entities { writer.handleReference(.softPointer, entity.handle) }
        writer.writeBitLong(Int32(action.parametersIds.count))
        for id in action.parametersIds { writer.writeBitLong(id) }
    }

    private func writeBlockActionBasePt(_ action: ACad.BlockActionBasePt) {
        writeBlockAction(action)
        writer.write3BitDouble(action.basePoint)
        writeEvalConnection(action.updateBaseXConnection)
        writeEvalConnection(action.updateBaseYConnection)
        writer.writeBit(action.value280)
        writer.write3BitDouble(action.value1012)
    }

    private func writeBlockAlignmentParameter(_ p: ACad.BlockAlignmentParameter) {
        writeBlock2PtParameter(p)
        writer.writeBit(p.isPerpendicular)
    }

    private func writeBlockBasePointParameter(_ p: ACad.BlockBasePointParameter) {
        writeBlock1PtParameter(p)
        writer.write3BitDouble(p.point1011)
        writer.write3BitDouble(p.point1012)
    }

    private func writeBlockElement(_ element: ACad.BlockElement) {
        writeEvaluationExpression(element)
        writer.writeVariableText(element.elementName)
        writer.writeBitLong(element.value98)
        writer.writeBitLong(element.value99)
        writer.writeBitLong(element.value1071)
    }

    private func writeBlockFlipParameter(_ p: ACad.BlockFlipParameter) {
        writeBlock2PtParameter(p)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
        writer.writeVariableText(p.baseStateName)
        writer.writeVariableText(p.flippedStateName)
        writer.write3BitDouble(p.labelPosition)
        writeEvalConnection(p.updatedFlipConnection)
    }

    private func writeBlockGrip(_ grip: ACad.BlockGrip) {
        writeBlockElement(grip)
        writer.writeBitLong(grip.expressionId1)
        writer.writeBitLong(grip.expressionId2)
        writer.write3BitDouble(grip.location)
        writer.writeBit(grip.cycling)
        writer.writeBitLong(grip.value93)
    }

    private func writeBlockLinearParameter(_ p: ACad.BlockLinearParameter) {
        writeBlock2PtParameter(p)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
        writer.writeBitDouble(p.labelOffset)
        writeParameterValueSet(p.valueSet)
    }

    private func writeBlockLookupAction(_ action: ACad.BlockLookupAction) {
        writeBlockAction(action)
        let nrows = action.columns.first?.rows.count ?? 0
        let ncols = action.columns.count
        writer.writeBitLong(Int32(nrows))
        writer.writeBitLong(Int32(ncols))
        for i in 0..<nrows {
            for j in 0..<ncols { writer.writeVariableText(action.columns[j].rows[i]) }
        }
        for column in action.columns {
            writer.writeBitLong(column.nodeId)
            writer.writeBitLong(column.valueType)
            writer.writeBitLong(column.type)
            writer.writeBit(column.isLookupProperty)
            writer.writeVariableText(column.unmatchedName)
            writer.writeBit(!column.isReadOnly)
            writer.writeVariableText(column.connectionName)
        }
        writer.writeBit(action.unknownFlag)
    }

    private func writeBlockLookupParameter(_ p: ACad.BlockLookupParameter) {
        writeBlock1PtParameter(p)
        writer.writeBitLong(p.actionId)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
    }

    private func writeBlockParameter(_ p: ACad.BlockParameter) {
        writeBlockElement(p)
        writer.writeBit(p.showProperties)
        writer.writeBit(p.chainActions)
    }

    private func writeBlockPointParameter(_ p: ACad.BlockPointParameter) {
        writeBlock1PtParameter(p)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
        writer.write3BitDouble(p.labelPosition)
    }

    private func writeBlockPolarParameter(_ p: ACad.BlockPolarParameter) {
        writeBlock2PtParameter(p)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
        writer.writeVariableText(p.angleName)
        writer.writeVariableText(p.angleDescription)
        writer.writeBitDouble(p.labelOffset)
        writeParameterValueSet(p.distanceValueSet)
        writeParameterValueSet(p.angleValueSet)
    }

    private func writeStretchData(_ action: ACad.StretchActionBase) {
        writer.writeBitLong(Int32(action.stretchBindings.count))
        for bind in action.stretchBindings {
            writer.handleReference(.softPointer, bind.entity?.handle ?? 0)
            writer.writeBitLong(Int32(bind.pointIndexes.count))
            for index in bind.pointIndexes { writer.writeBitLong(index) }
        }
        writer.writeBitLong(Int32(action.stretchNodes.count))
        for node in action.stretchNodes {
            writer.writeBitLong(node.nodeId)
            writer.writeBitLong(Int32(node.pointIndexes.count))
            for index in node.pointIndexes { writer.writeBitLong(index) }
        }
        writer.writeBitDouble(action.distanceMultiplier)
        writer.writeBitDouble(action.angleOffset)
    }

    private func writeBlockPolarStretchAction(_ action: ACad.BlockPolarStretchAction) {
        writeBlockAction(action)
        writeEvalConnection(action.baseXDeltaConnection)
        writeEvalConnection(action.baseYDeltaConnection)
        writeEvalConnection(action.baseConnection)
        writeEvalConnection(action.endConnection)
        writeEvalConnection(action.updatedBaseConnection)
        writeEvalConnection(action.updatedEndConnection)
        writer.writeBitLong(Int32(action.boundary.count))
        for pt in action.boundary { writer.write2RawDouble(pt) }
        writer.writeBitLong(Int32(action.rotateBindings.count))
        for bind in action.rotateBindings { writer.handleReference(.softPointer, bind.handle) }
        writeStretchData(action)
        writer.writeBitLong(0)
    }

    private func writeBlockRotationParameter(_ p: ACad.BlockRotationParameter) {
        writeBlock2PtParameter(p)
        writer.write3BitDouble(p.point)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
        writer.writeBitDouble(p.labelOffset)
        writeParameterValueSet(p.valueSet)
    }

    private func writeBlockStretchAction(_ action: ACad.BlockStretchAction) {
        writeBlockAction(action)
        writeEvalConnection(action.endXDeltaConnection)
        writeEvalConnection(action.endYDeltaConnection)
        writer.writeBitLong(Int32(action.boundary.count))
        for pt in action.boundary { writer.write2RawDouble(pt) }
        writeStretchData(action)
        writer.writeByte(action.unknownFlag)
    }

    private func writeBlockVisibilityParameter(_ p: ACad.BlockVisibilityParameter) {
        writeBlock1PtParameter(p)
        writer.writeBit(p.chainActions)
        writer.writeVariableText(p.label)
        writer.writeVariableText(p.description)
        writer.writeBit(p.value91)
        writer.writeBitLong(Int32(p.entities.count))
        for e in p.entities { writer.handleReference(.softPointer, e.handle) }
        writer.writeBitLong(Int32(p.states.count))
        for state in p.states.values {
            writer.writeVariableText(state.name)
            writer.writeBitLong(Int32(state.entities.count))
            for entity in state.entities { writer.handleReference(.softPointer, entity.handle) }
            writer.writeBitLong(Int32(state.expressions.count))
            for expression in state.expressions { writer.handleReference(.softPointer, expression.handle) }
        }
    }

    private func writeBlockXYParameter(_ p: ACad.BlockXYParameter) {
        writeBlock2PtParameter(p)
        writer.writeVariableText(p.labelY)
        writer.writeVariableText(p.labelX)
        writer.writeVariableText(p.descriptionY)
        writer.writeVariableText(p.descriptionX)
        writer.writeBitDouble(p.labelOffsetX)
        writer.writeBitDouble(p.labelOffsetY)
        writeParameterValueSet(p.valueSetX)
        writeParameterValueSet(p.valueSetY)
    }

    /// A null connection is a null reference in ACadSharp.
    private func writeEvalConnection(_ connection: ACad.EvalConnection?) {
        let connection = connection ?? ACad.EvalConnection()
        writer.writeBitLong(connection.id)
        writer.writeVariableText(connection.name)
    }

    private func writeEvalParameterProperty(_ property: ACad.EvalParameterProperty) {
        writer.writeBitShort(Int16(truncatingIfNeeded: property.connections.count))
        for connection in property.connections { writeEvalConnection(connection) }
    }

    private func writeEvaluationExpression(_ expression: ACad.EvaluationExpression) {
        writer.writeBitLong(expression.unknown)
        writer.writeBitLong(expression.value98)
        writer.writeBitLong(expression.value99)
        if let value = expression.evaluatedValue {
            writer.writeBitShort(Int16(truncatingIfNeeded: value.code))
            switch (ACad.GroupCodeValueType.of(value.code), value.value) {
            case (.string, .string(let s)), (.extendedDataString, .string(let s)): writer.writeVariableText(s)
            case (.int16, .int16(let v)), (.extendedDataInt16, .int16(let v)): writer.writeBitShort(v)
            case (.double, .double(let v)), (.extendedDataDouble, .double(let v)): writer.writeBitDouble(v)
            case (.int32, .int32(let v)), (.extendedDataInt32, .int32(let v)): writer.writeBitLong(v)
            case (.int64, .int64(let v)): writer.writeBitLong(Int32(truncatingIfNeeded: v))
            case (.point3D, .point(let v)): writer.write3BitDouble(v)
            default:
                // The C# casts / the unimplemented code types throw; the queue reports the object as unreadable.
                writer.writeBitLong(expression.id)
                return
            }
        } else {
            writer.writeBitShort(-9999) // DxfCode.Invalid
        }
        writer.writeBitLong(expression.id)
    }

    private func writeEvaluationGraph(_ graph: ACad.EvaluationGraph) {
        writer.writeBitLong(graph.value96)
        writer.writeBitLong(graph.value97)
        writer.writeBitLong(Int32(graph.nodes.count))
        for (i, node) in graph.nodes.enumerated() {
            writer.writeBitLong(Int32(i))
            writer.writeBitLong(node.flags)
            writer.writeBitLong(node.id)
            writer.handleReference(.hardOwnership, node.expression?.handle ?? 0)
            writer.writeBitLong(node.data1)
            writer.writeBitLong(node.data2)
            writer.writeBitLong(node.data3)
            writer.writeBitLong(node.data4)
        }
        writer.writeBitLong(Int32(graph.edges.count))
        for (i, edge) in graph.edges.enumerated() {
            writer.writeBitLong(Int32(i))
            writer.writeBitLong(edge.flags)
            writer.writeBitLong(edge.trackedCount)
            writer.writeBitLong(edge.fromNodeIndex)
            writer.writeBitLong(edge.toNodeIndex)
            writer.writeBitLong(edge.data1)
            writer.writeBitLong(edge.data2)
            writer.writeBitLong(edge.data3)
            writer.writeBitLong(edge.data4)
            writer.writeBitLong(edge.data5)
        }
        addObjectsToWriter(graph.nodes.compactMap(\.expression))
    }

    private func writeParameterValueSet(_ valueSet: ACad.ParameterValueSet?) {
        let valueSet = valueSet ?? ACad.ParameterValueSet()
        writer.writeBitLong(valueSet.type)
        writer.writeBitDouble(valueSet.minimum)
        writer.writeBitDouble(valueSet.maximum)
        writer.writeBitDouble(valueSet.increment)
        writer.writeBitLong(Int32(valueSet.allowedValues.count))
        for value in valueSet.allowedValues { writer.writeBitDouble(value) }
    }

    // ───────────────────────── Objects ─────────────────────────

    private func writeBookColor(_ color: ACad.BookColor) {
        writer.writeBitShort(0)
        // R2004+
        let c = color.color
        writer.writeBitLong(Int32(bitPattern: UInt32(c.b) | UInt32(c.g) << 8 | UInt32(c.r) << 16 | 0b1100_0010 << 24))
        var flags: UInt8 = 0
        if !color.name.isEmpty { flags |= 1 }
        if let book = color.bookName, !book.isEmpty { flags |= 2 }
        writer.writeByte(flags)
        if let name = color.colorName, !name.isEmpty { writer.writeVariableText(name) }
        if let book = color.bookName, !book.isEmpty { writer.writeVariableText(book) }
    }

    private func writeBorder(_ border: ACad.TableStyle.CellBorder) {
        guard border.applyBorder else { return }
        writer.writeBitLong(border.edgeFlags)
        writer.writeBitLong(border.propertyOverrideFlags)
        writer.writeBitLong(Int32(border.type))
        writer.writeCmColor(border.color)
        writer.writeBitLong(Int32(border.lineWeight.rawValue))
        writer.handleReference(.hardPointer, 0)
        writer.writeBitLong(border.isInvisible ? 1 : 0)
        writer.writeBitDouble(border.doubleLineSpacing)
    }

    func writeCadValue(_ value: ACad.CadValue) throws {
        // R2007+
        writer.writeBitLong(value.flags)
        writer.writeBitLong(value.valueType)
        if !value.isEmpty {
            switch value.valueType {
            case ACad.CadValueType.unknown:
                writer.writeBitLong(0)
            case ACad.CadValueType.long:
                guard case let .int(v)? = value.value else { throw ACad.DxfWriteError.nullReference }
                writer.writeBitLong(v)
            case ACad.CadValueType.double:
                guard case let .double(v)? = value.value else { throw ACad.DxfWriteError.nullReference }
                writer.writeBitDouble(v)
            case ACad.CadValueType.general, ACad.CadValueType.string:
                if case let .string(s)? = value.value { try writeStringCadValue(s) } else { try writeStringCadValue(nil) }
            case ACad.CadValueType.date:
                if case let .date(d)? = value.value { writeDateCadValue(d) } else { writer.writeBitLong(0) }
            case ACad.CadValueType.point2D:
                if case let .point2D(p)? = value.value {
                    writer.writeBitLong(16)
                    writer.write2RawDouble(p)
                } else {
                    writer.writeBitLong(0)
                }
            case ACad.CadValueType.point3D:
                if case let .point3D(p)? = value.value {
                    writer.writeBitLong(24)
                    writer.writeRawDouble(p.x)
                    writer.writeRawDouble(p.y)
                    writer.writeRawDouble(p.z)
                } else {
                    writer.writeBitLong(0)
                }
            case ACad.CadValueType.handle:
                if case let .object(o)? = value.value {
                    writer.handleReference(.softPointer, o.handle)
                } else {
                    writer.handleReference(.softPointer, 0)
                }
            default:
                throw ACad.DwgError.notImplemented
            }
        }
        // R2007+
        writer.writeBitLong(value.units)
        writer.writeVariableText(value.format)
        writer.writeVariableText(value.formattedValue)
    }

    func writeCellContentFormatPublic(_ format: ACad.TableStyle.ContentFormat) { writeCellContentFormat(format) }

    private func writeCellContentFormat(_ format: ACad.TableStyle.ContentFormat) {
        writer.writeBitLong(format.propertyOverrideFlags)
        writer.writeBitLong(format.propertyFlags)
        writer.writeBitLong(format.valueDataType)
        writer.writeBitLong(format.valueUnitType)
        writer.writeVariableText(format.valueFormatString)
        writer.writeBitDouble(format.rotation)
        writer.writeBitDouble(format.scale)
        writer.writeBitLong(format.alignment)
        writer.writeCmColor(format.color)
        writer.handleReference(.hardPointer, format.textStyle?.handle ?? 0)
        writer.writeBitDouble(format.textHeight)
    }

    func writeCellStyle(_ style: ACad.TableStyle.CellStyle) {
        writer.writeBitLong(style.type)
        writer.writeBitShort(style.hasData ? 1 : 0)
        guard style.hasData else { return }
        writer.writeBitLong(style.propertyOverrideFlags)
        writer.writeBitLong(style.tableCellStylePropertyFlags)
        writer.writeCmColor(style.backgroundColor)
        writer.writeBitLong(style.contentLayoutFlags)
        writeCellContentFormat(style)
        writer.writeBitShort(Int16(truncatingIfNeeded: style.marginOverrideFlags))
        if style.marginOverrideFlags & 1 != 0 { // MarginFlags.Override
            writer.writeBitDouble(style.verticalMargin)
            writer.writeBitDouble(style.horizontalMargin)
            writer.writeBitDouble(style.bottomMargin)
            writer.writeBitDouble(style.rightMargin)
            writer.writeBitDouble(style.marginHorizontalSpacing)
            writer.writeBitDouble(style.marginVerticalSpacing)
        }
        let borders = [style.topBorder, style.rightBorder, style.bottomBorder, style.leftBorder,
                       style.verticalInsideBorder, style.horizontalInsideBorder]
        writer.writeBitLong(Int32(borders.filter(\.applyBorder).count))
        for border in borders { writeBorder(border) }
    }

    private func writeCellStyleWithId(_ style: ACad.TableStyle.CellStyle) {
        writeCellStyle(style)
        writer.writeBitLong(style.id)
        writer.writeBitLong(style.styleClass)
        writer.writeVariableText(style.name)
    }

    /// R2007+: SYSTEMTIME as 8 shorts (year, month, day of week, day, hour, minute, second, millisecond), local time.
    private func writeDateCadValue(_ date: Date) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .weekday, .day, .hour, .minute, .second, .nanosecond], from: date)
        var array: [UInt8] = []
        for v in [c.year!, c.month!, c.weekday! - 1, c.day!, c.hour!, c.minute!, c.second!, c.nanosecond! / 1_000_000] {
            array += ACad.DwgLE.bytes(Int16(truncatingIfNeeded: v))
        }
        writer.writeBitLong(Int32(array.count))
        writer.writeBytes(array)
    }

    private func writeDictionary(_ dictionary: ACad.CadDictionary) throws {
        var entries: [ACad.NonGraphicalObject] = []
        for item in dictionary.values where !(try skipEntry(item)) { entries.append(item) }
        writer.writeBitLong(Int32(entries.count))
        // R2000+
        writer.writeBitShort(dictionary.cloningFlags)
        writer.writeByte(dictionary.hardOwnerFlag ? 1 : 0)
        for item in entries where !(try skipEntry(item)) {
            writer.writeVariableText(item.name)
            writer.handleReference(.softOwnership, item.handle)
        }
        addObjectsToWriter(entries)
    }

    private func writeDimensionAssociation(_ association: ACad.DimensionAssociation) {
        typealias F = ACad.DimensionAssociation.Flags
        writer.handleReference(.softPointer, association.dimension?.handle ?? 0)
        writer.writeBitLong(Int32(association.associativityFlags))
        writer.writeBit(association.isTransSpace)
        writer.writeByte(UInt8(truncatingIfNeeded: association.rotatedDimensionType))
        let flags = association.associativityFlags
        if flags & F.firstPointReference != 0 { writeOsnapPointRef(association.firstPointRef) }
        if flags & F.secondPointReference != 0 { writeOsnapPointRef(association.secondPointRef) }
        if flags & F.thirdPointReference != 0 { writeOsnapPointRef(association.thirdPointRef) }
        if flags & F.fourthPointReference != 0 { writeOsnapPointRef(association.fourthPointRef) }
    }

    private func writeOsnapPointRef(_ osnap: ACad.DimensionAssociation.OsnapPointRef?) {
        writer.writeVariableText(ACad.DimensionAssociation.osnapPointRefClassName)
        writer.writeByte(UInt8(truncatingIfNeeded: osnap?.objectOsnapType ?? 0))
        writer.handleReference(.undefined, osnap?.geometry?.handle ?? 0)
    }

    private func writeField(_ field: ACad.Field) throws {
        writer.writeVariableText(field.evaluatorId)
        writer.writeVariableText(field.fieldCode)
        writer.writeBitLong(Int32(field.children.count))
        for f in field.children { writer.handleReference(.hardOwnership, f.handle) }
        writer.writeBitLong(Int32(field.cadObjects.count))
        for o in field.cadObjects { writer.handleReference(.softPointer, o.handle) }
        writer.writeBitLong(field.evaluationOptionFlags)
        writer.writeBitLong(field.filingOptionFlags)
        writer.writeBitLong(field.fieldStateFlags)
        writer.writeBitLong(field.evaluationStatusFlags)
        writer.writeBitLong(field.evaluationErrorCode)
        writer.writeVariableText(field.evaluationErrorMessage)
        try writeCadValue(field.value)
        writer.writeVariableText(field.formatString)
        // `FormatString.Length`: a null format string is a null reference.
        guard let format = field.formatString else { throw ACad.DxfWriteError.nullReference }
        writer.writeBitLong(Int32(format.utf16.count))
        writer.writeBitLong(Int32(field.values.count))
        for (key, value) in field.values.pairs {
            writer.writeVariableText(key)
            try writeCadValue(value)
        }
        for child in field.children { enqueueValidObject(child) }
    }

    private func writeGeoData(_ geo: ACad.GeoData) {
        writer.writeBitLong(geo.version)
        writer.handleReference(.softPointer, geo.hostBlock?.handle ?? 0)
        writer.writeBitShort(geo.coordinatesType)
        switch geo.version {
        case ACad.GeoData.GeoDataVersion.r2009:
            writer.write3BitDouble(geo.referencePoint)
            writer.writeBitLong(geo.horizontalUnits)
            writer.write3BitDouble(geo.designPoint)
            writer.write3BitDouble(.zero)
            writer.write3BitDouble(geo.upDirection)
            writer.writeBitDouble(Double.pi / 2.0 - geo.northDirection.angle)
            writer.write3BitDouble(XYZ(1, 1, 1))
            writer.writeVariableText(geo.coordinateSystemDefinition)
            writer.writeVariableText(geo.geoRssTag)
            writer.writeBitDouble(geo.horizontalUnitScale)
            geo.verticalUnitScale = geo.horizontalUnitScale
            writer.writeVariableText("")
            writer.writeVariableText("")
        case ACad.GeoData.GeoDataVersion.r2010, ACad.GeoData.GeoDataVersion.r2013:
            writer.write3BitDouble(geo.designPoint)
            writer.write3BitDouble(geo.referencePoint)
            writer.writeBitDouble(geo.horizontalUnitScale)
            writer.writeBitLong(geo.horizontalUnits)
            writer.writeBitDouble(geo.verticalUnitScale)
            writer.writeBitLong(geo.horizontalUnits)
            writer.write3BitDouble(geo.upDirection)
            writer.write2RawDouble(geo.northDirection)
            writer.writeBitLong(geo.scaleEstimationMethod)
            writer.writeBitDouble(geo.userSpecifiedScaleFactor)
            writer.writeBit(geo.enableSeaLevelCorrection)
            writer.writeBitDouble(geo.seaLevelElevation)
            writer.writeBitDouble(geo.coordinateProjectionRadius)
            writer.writeVariableText(geo.coordinateSystemDefinition)
            writer.writeVariableText(geo.geoRssTag)
        default:
            break
        }
        writer.writeVariableText(geo.observationFromTag)
        writer.writeVariableText(geo.observationToTag)
        writer.writeVariableText(geo.observationCoverageTag)
        writer.writeBitLong(Int32(geo.points.count))
        for pt in geo.points {
            writer.write2RawDouble(pt.source)
            writer.write2RawDouble(pt.destination)
        }
        writer.writeBitLong(Int32(geo.faces.count))
        for face in geo.faces {
            writer.writeBitLong(face.index1)
            writer.writeBitLong(face.index2)
            writer.writeBitLong(face.index3)
        }
    }

    private func writeLayout(_ layout: ACad.Layout) {
        writePlotSettings(layout)
        writer.writeVariableText(layout.name)
        writer.writeBitLong(layout.tabOrder)
        writer.writeBitShort(layout.layoutFlags)
        writer.write3BitDouble(layout.origin)
        // ACadSharp writes the minimum limits twice.
        writer.write2RawDouble(layout.minLimits)
        writer.write2RawDouble(layout.minLimits)
        writer.write3BitDouble(layout.insertionBasePoint)
        writer.write3BitDouble(layout.xAxis)
        writer.write3BitDouble(layout.yAxis)
        writer.writeBitDouble(layout.elevation)
        writer.writeBitShort(layout.ucsOrthographicType)
        writer.write3BitDouble(layout.minExtents)
        writer.write3BitDouble(layout.maxExtents)
        // R2004+
        let viewports = layout.viewports
        writer.writeBitLong(Int32(viewports.count))
        writer.handleReference(.softPointer, layout.associatedBlock?.handle ?? 0)
        writer.handleReference(.softPointer, layout.lastActiveViewport?.handle ?? 0)
        if layout.ucsOrthographicType == 0 {
            writer.handleReference(.hardPointer, 0)
            writer.handleReference(.hardPointer, layout.ucs?.handle ?? 0)
        } else {
            writer.handleReference(.hardPointer, layout.baseUCS?.handle ?? 0)
            writer.handleReference(.hardPointer, 0)
        }
        // R2004+
        for viewport in viewports { writer.handleReference(.softPointer, viewport.handle) }
    }

    private func writeMaterial(_ m: ACad.Material) {
        writer.writeVariableText(m.name)
        writer.writeVariableText(m.description ?? "")
        writeMaterialColor(m.ambientColorMethod, m.ambientColorFactor, m.ambientColor)
        writeMaterialColor(m.diffuseColorMethod, m.diffuseColorFactor, m.diffuseColor)
        writeMaterialMap(m.diffuse)
        writeMaterialColor(m.specularColorMethod, m.specularColorFactor, m.specularColor)
        writeMaterialMap(m.specular)
        writer.writeBitDouble(m.specularGlossFactor)
        writeMaterialMap(m.reflection)
        writer.writeBitDouble(m.opacity)
        writeMaterialMap(m.opacityMap)
        writeMaterialMap(m.bump)
        writer.writeBitDouble(m.refractionIndex)
        writeMaterialMap(m.refraction)
        // R2007+
        writer.writeBitDouble(m.translucence)
        writer.writeBitDouble(m.selfIllumination)
        writer.writeBitDouble(m.reflectivity)
        writer.writeBitLong(m.illuminationModel)
        writer.writeBitLong(m.channelFlags)
        writer.writeBitLong(m.mode)
    }

    private func writeMaterialColor(_ method: UInt8, _ factor: Double, _ rgb: ACad.Color) {
        writer.writeByte(method)
        writer.writeBitDouble(factor)
        if method == 1 { // ColorMethod.Override
            writer.writeBitLong(Int32(bitPattern: UInt32(rgb.b) | UInt32(rgb.g) << 8 | UInt32(rgb.r) << 16 | 0b1100_0010 << 24))
        }
    }

    private func writeMaterialMap(_ map: ACad.Material.MapChannel) {
        writer.writeBitDouble(map.blendFactor)
        writer.writeByte(map.projection)
        writer.writeByte(map.tiling)
        writer.writeByte(map.autoTransform)
        // M00, M01, M02, M03, M10 … (row by row)
        for v in map.matrix { writer.writeBitDouble(v) }
        writer.writeByte(map.source)
        if map.source == 1 { // MapSource.UseImageFile
            writer.writeVariableText(map.fileName ?? "")
        }
    }

    private func writeMLineStyle(_ style: ACad.MLineStyle) {
        writer.writeVariableText(style.name)
        writer.writeVariableText(style.description)
        // MLineStyleFlags: FillOn 1, DisplayJoints 2, StartSquareCap 16, StartInnerArcsCap 32, StartRoundCap 64,
        // EndSquareCap 256, EndInnerArcsCap 512, EndRoundCap 1024.
        let f = style.flags
        var flags: Int16 = 0
        if f & 2 != 0 { flags |= 1 }
        if f & 1 != 0 { flags |= 2 }
        if f & 16 != 0 { flags |= 16 }
        if f & 64 != 0 { flags |= 0x20 }
        if f & 32 != 0 { flags |= 0x40 }
        if f & 256 != 0 { flags |= 0x100 }
        if f & 1024 != 0 { flags |= 0x200 }
        if f & 512 != 0 { flags |= 0x400 }
        writer.writeBitShort(flags)
        writer.writeCmColor(style.fillColor)
        writer.writeBitDouble(style.startAngle)
        writer.writeBitDouble(style.endAngle)
        writer.writeByte(UInt8(truncatingIfNeeded: style.elements.count))
        for element in style.elements {
            writer.writeBitDouble(element.offset)
            writer.writeCmColor(element.color)
            // R2018+
            writer.handleReference(.hardPointer, element.lineType.handle)
        }
    }

    private func writeMultiLeaderStyle(_ s: ACad.MultiLeaderStyle) {
        // R2010+
        writer.writeBitShort(2)
        writer.writeBitShort(s.contentType)
        writer.writeBitShort(s.multiLeaderDrawOrder)
        writer.writeBitShort(s.leaderDrawOrder)
        writer.writeBitLong(Int32(Int16(truncatingIfNeeded: s.maxLeaderSegmentsPoints)))
        writer.writeBitDouble(s.firstSegmentAngleConstraint)
        writer.writeBitDouble(s.secondSegmentAngleConstraint)
        writer.writeBitShort(s.pathType)
        writer.writeCmColor(s.lineColor)
        writer.handleReference(.hardPointer, s.leaderLineType.handle)
        writer.writeBitLong(Int32(s.leaderLineWeight.rawValue))
        writer.writeBit(s.enableLanding)
        writer.writeBitDouble(s.landingGap)
        writer.writeBit(s.enableDogleg)
        writer.writeBitDouble(s.landingDistance)
        writer.writeVariableText(s.description)
        writer.handleReference(.hardPointer, s.arrowhead?.handle ?? 0)
        writer.writeBitDouble(s.arrowheadSize)
        writer.writeVariableText(s.defaultTextContents)
        writer.handleReference(.hardPointer, s.textStyle.handle)
        writer.writeBitShort(s.textLeftAttachment)
        writer.writeBitShort(s.textRightAttachment)
        writer.writeBitShort(s.textAngle)
        writer.writeBitShort(s.textAlignment)
        writer.writeCmColor(s.textColor)
        writer.writeBitDouble(s.textHeight)
        writer.writeBit(s.textFrame)
        writer.writeBit(s.textAlignAlwaysLeft)
        writer.writeBitDouble(s.alignSpace)
        writer.handleReference(.hardPointer, s.blockContent?.handle ?? 0)
        writer.writeCmColor(s.blockContentColor)
        writer.write3BitDouble(s.blockContentScale)
        writer.writeBit(s.enableBlockContentScale)
        writer.writeBitDouble(s.blockContentRotation)
        writer.writeBit(s.enableBlockContentRotation)
        writer.writeBitShort(s.blockContentConnection)
        writer.writeBitDouble(s.scaleFactor)
        writer.writeBit(s.overwritePropertyValue)
        writer.writeBit(s.isAnnotative)
        writer.writeBitDouble(s.breakGapSize)
        // R2010+
        writer.writeBitShort(s.textAttachmentDirection)
        writer.writeBitShort(s.textBottomAttachment)
        writer.writeBitShort(s.textTopAttachment)
        // R2013+
        writer.writeBit(s.unknownFlag298)
    }

    private func writePlotSettings(_ plot: ACad.PlotSettings) {
        writer.writeVariableText(plot.pageName)
        writer.writeVariableText(plot.systemPrinterName)
        writer.writeBitShort(plot.flags)
        writer.writeBitDouble(plot.unprintableMargin.left)
        writer.writeBitDouble(plot.unprintableMargin.bottom)
        writer.writeBitDouble(plot.unprintableMargin.right)
        writer.writeBitDouble(plot.unprintableMargin.top)
        writer.writeBitDouble(plot.paperWidth)
        writer.writeBitDouble(plot.paperHeight)
        writer.writeVariableText(plot.paperSize)
        writer.writeBitDouble(plot.plotOriginX)
        writer.writeBitDouble(plot.plotOriginY)
        writer.writeBitShort(plot.paperUnits)
        writer.writeBitShort(plot.paperRotation)
        writer.writeBitShort(plot.plotType)
        writer.writeBitDouble(plot.windowLowerLeftX)
        writer.writeBitDouble(plot.windowLowerLeftY)
        writer.writeBitDouble(plot.windowUpperLeftX)
        writer.writeBitDouble(plot.windowUpperLeftY)
        writer.writeBitDouble(plot.numeratorScale)
        writer.writeBitDouble(plot.denominatorScale)
        writer.writeVariableText(plot.styleSheet)
        writer.writeBitShort(plot.scaledFit)
        writer.writeBitDouble(plot.standardScale)
        writer.write2BitDouble(XY(plot.paperImageOriginX, plot.paperImageOriginY))
        // R2004+
        writer.writeBitShort(plot.shadePlotMode)
        writer.writeBitShort(plot.shadePlotResolutionMode)
        writer.writeBitShort(plot.shadePlotDPI)
        writer.handleReference(.hardPointer, 0)
        // R2007+
        writer.handleReference(.softPointer, 0)
    }

    private func writeSpatialFilter(_ filter: ACad.SpatialFilter) {
        writer.writeBitShort(Int16(truncatingIfNeeded: filter.boundaryPoints.count))
        for pt in filter.boundaryPoints { writer.write2RawDouble(pt) }
        writer.write3BitDouble(filter.normal)
        writer.write3BitDouble(filter.origin)
        writer.writeBitShort(filter.displayBoundary ? 1 : 0)
        writer.writeBitShort(filter.clipFrontPlane ? 1 : 0)
        if filter.clipFrontPlane { writer.writeBitDouble(filter.frontDistance) }
        writer.writeBitShort(filter.clipBackPlane ? 1 : 0)
        if filter.clipBackPlane { writer.writeBitDouble(filter.backDistance) }
        write4x3Matrix(filter.inverseInsertTransform)
        write4x3Matrix(filter.insertTransform)
    }

    /// `write4x3Matrix`: rows 0–2 of the row-major 4×4 matrix.
    private func write4x3Matrix(_ m: [Double]) {
        for i in 0..<3 {
            for j in 0..<4 { writer.writeBitDouble(m[i * 4 + j]) }
        }
    }

    /// R2007+: UTF-16 with a 2-byte terminator. ACadSharp writes a 0 length first for empty strings and still writes
    /// the (empty) text after it.
    private func writeStringCadValue(_ value: String?) throws {
        if value?.isEmpty ?? true { writer.writeBitLong(0) }
        guard let value else { throw ACad.DwgError("Value cannot be null. (Parameter 's')") }
        let bytes = value.utf16.flatMap { ACad.DwgLE.bytes($0) }
        writer.writeBitLong(Int32(bytes.count + 2))
        writer.writeBytes(bytes)
        writer.writeByte(0)
        writer.writeByte(0)
    }

    private func writeTableStyle(_ style: ACad.TableStyle) throws {
        // R2007+
        writer.writeByte(0)
        writer.writeVariableText(style.description)
        writer.writeBitLong(0)
        writer.writeBitLong(0)
        writer.handleReference(.hardOwnership, 0)
        writeCellStyleWithId(style.tableCellStyle)
        var nCellStyles = style.cellStyles.count
        let named: [ACad.TableStyle.CellStyle?] = [style.titleCellStyle, style.headerCellStyle, style.dataCellStyle]
        for s in named {
            if let s, !style.cellStyles.contains(where: { $0 === s }) { nCellStyles += 1 }
        }
        writer.writeBitLong(Int32(nCellStyles))
        var index: Int32 = 1
        for s in named {
            guard let s else { continue }
            writer.writeBitLong(index)
            index += 1
            writeCellStyleWithId(s)
        }
        index = 101
        for cellStyle in style.cellStyles where !named.contains(where: { $0 === cellStyle }) {
            writer.writeBitLong(index)
            writeCellStyleWithId(cellStyle)
            index += 1
        }
    }

    private func writeXRecord(_ record: ACad.XRecord) throws {
        var ms: [UInt8] = []
        for entry in record.entries {
            ms += ACad.DwgLE.bytes(Int16(truncatingIfNeeded: entry.code))
            let value = entry.value
            switch ACad.GroupCodeValueType.of(entry.code) {
            case .byte, .bool:
                ms.append(UInt8(truncatingIfNeeded: try Self.convertToInt(value, min: 0, max: 255)))
            case .int16, .extendedDataInt16:
                ms += ACad.DwgLE.bytes(Int16(try Self.convertToInt(value, min: Int64(Int16.min), max: Int64(Int16.max))))
            case .int32, .extendedDataInt32:
                ms += ACad.DwgLE.bytes(Int32(try Self.convertToInt(value, min: Int64(Int32.min), max: Int64(Int32.max))))
            case .int64:
                ms += ACad.DwgLE.bytes(try Self.convertToInt(value, min: Int64.min, max: Int64.max))
            case .double, .extendedDataDouble:
                guard case let .double(d) = value else { throw ACad.DwgError("Nullable object must have a value.") }
                ms += ACad.DwgLE.bytes(d)
            case .point3D:
                guard case let .point(p) = value else { throw ACad.DwgError("Nullable object must have a value.") }
                ms += ACad.DwgLE.bytes(p.x) + ACad.DwgLE.bytes(p.y) + ACad.DwgLE.bytes(p.z)
            case .chunk, .extendedDataChunk:
                guard case let .bytes(data) = value else { throw ACad.DwgError("Specified cast is not valid.") }
                ms.append(UInt8(truncatingIfNeeded: data.count))
                ms += data
            case .handle:
                let object = Self.handleValue(value).flatMap { document.object($0) }
                writeStringInStream(&ms, object.map { String($0.handle, radix: 16, uppercase: true) } ?? "")
            case .string, .extendedDataString:
                writeStringInStream(&ms, Self.convertToString(value))
            case .objectId, .extendedDataHandle:
                let object = Self.handleValue(value).flatMap { document.object($0) }
                ms += ACad.DwgLE.bytes(object?.handle ?? 0)
            default:
                throw ACad.DwgError("Specified method is not supported.")
            }
        }
        writer.writeBitLong(Int32(ms.count))
        writer.writeBytes(ms)
        // R2000+
        writer.writeBitShort(record.cloningFlags)
    }

    private static func handleValue(_ value: ACad.DxfValue) -> UInt64? {
        if case let .handle(h) = value { return h }
        return nil
    }

    /// `Convert.ToInt…(value, InvariantCulture)` for the values an XRecord holds.
    private static func convertToInt(_ value: ACad.DxfValue, min: Int64, max: Int64) throws -> Int64 {
        let result: Int64
        switch value {
        case let .int16(v): result = Int64(v)
        case let .int32(v): result = Int64(v)
        case let .int64(v): result = v
        case let .byte(v): result = Int64(v)
        case let .bool(b): result = b ? 1 : 0
        case let .handle(h): result = Int64(bitPattern: h)
        case let .double(d):
            let r = d.rounded(.toNearestOrEven)
            guard r >= Double(min), r <= Double(max) else { throw ACad.DwgError("Value was either too large or too small.") }
            return Int64(r)
        case let .string(s):
            guard let v = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                throw ACad.DwgError("The input string '\(s)' was not in a correct format.")
            }
            result = v
        case .point, .bytes:
            throw ACad.DwgError("Unable to cast object to type 'System.IConvertible'.")
        }
        guard result >= min, result <= max else { throw ACad.DwgError("Value was either too large or too small.") }
        return result
    }

    /// `Convert.ToString(value, InvariantCulture)`.
    private static func convertToString(_ value: ACad.DxfValue) -> String {
        switch value {
        case let .string(s): return s
        case let .double(d): return ACad.DxfNumber.netString(d)
        case let .int16(v): return String(v)
        case let .int32(v): return String(v)
        case let .int64(v): return String(v)
        case let .byte(v): return String(v)
        case let .bool(b): return b ? "True" : "False"
        case let .handle(h): return String(h)
        case .point: return "ACadSharp.CSMath.XYZ"
        case .bytes: return "System.Byte[]"
        }
    }

    /// `writeStringInStream` (R2007+): UTF-16 length and text.
    private func writeStringInStream(_ ms: inout [UInt8], _ text: String) {
        let units = Array(text.utf16)
        ms += ACad.DwgLE.bytes(Int16(truncatingIfNeeded: units.count))
        for u in units { ms += ACad.DwgLE.bytes(u) }
    }
}
