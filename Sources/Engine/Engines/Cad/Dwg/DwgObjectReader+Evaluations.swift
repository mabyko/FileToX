// ACadSharp 3.8.0 DwgObjectReader (DwgObjectReader.Objects.cs and the matching parts of DwgObjectReader.cs): dynamic
// block objects (evaluation graph, parameters, grips, actions), fields, object context data, dimension
// associativity, AEC walls and their styles, and AutoCAD Mechanical entities.

import Foundation

fileprivate typealias A = ACad

extension ACad {
    /// `DynamicBlockPurgePreventerTemplate`.
    final class DynamicBlockPurgePreventerTemplate: CadTemplate {
        var blockHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let record: BlockRecord = tableReference(builder, blockHandle, nil) {
                (cadObject as! DynamicBlockPurgePreventer).block = record
            }
        }
    }

    /// `CadWallTemplate`.
    final class CadWallTemplate: CadEntityTemplate {
        var cleanupGroupHandle: UInt64?
        var rawData: [UInt8]?
        var styleHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let wall = cadObject as! Wall
            if let rawData { wall.rawData = rawData }
            // The bin record handle is never read (ACadSharp's BinRecordHandle stays null).
            if let style: AecWallStyle = builder.tryGetObject(styleHandle) { wall.style = style }
            if let group: AecCleanupGroup = builder.tryGetObject(cleanupGroupHandle) { wall.cleanupGroup = group }
        }
    }

    /// `CadAcmBalloonTemplate` (the other mechanical templates only keep handles nothing uses).
    final class CadAcmBalloonTemplate: CadEntityTemplate {
        var blockHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let record: BlockRecord = tableReference(builder, blockHandle, nil) {
                (cadObject as! AcmBalloon).block = record
            }
        }
    }
}

extension ACad.DwgObjectReader {
    // ───────────────────────── Evaluation graph ─────────────────────────

    func readEvaluationGraph() throws -> ACad.CadTemplate? {
        let evaluationGraph = A.EvaluationGraph()
        let template = A.CadEvaluationGraphTemplate(evaluationGraph)

        try readCommonNonEntityData(template)

        // DXF fields 96, 97 contain the value 5
        evaluationGraph.value96 = try objectReader.readBitLong()
        evaluationGraph.value97 = try objectReader.readBitLong()

        let nodeCount = try objectReader.readBitLong()
        var i: Int32 = 0
        while i < nodeCount {
            let node = evaluationGraph.createNode()
            // Code 91
            node.index = try objectReader.readBitLong()
            // Code 93
            node.flags = try objectReader.readBitLong()
            // Code 95
            node.id = try objectReader.readBitLong()
            // Code 360
            let expressionHandle = try handleReference()
            template.nodeTemplates.append((node, expressionHandle))
            // Codes 92, x4
            node.data1 = try objectReader.readBitLong()
            node.data2 = try objectReader.readBitLong()
            node.data3 = try objectReader.readBitLong()
            node.data4 = try objectReader.readBitLong()
            i += 1
        }

        let edgeCount = try objectReader.readBitLong()
        var e: Int32 = 0
        while e < edgeCount {
            var edge = A.EvaluationGraph.Edge()
            // 92 index
            edge.index = try objectReader.readBitLong()
            // 93
            edge.flags = try objectReader.readBitLong()
            // 94
            edge.trackedCount = try objectReader.readBitLong()
            // 91
            edge.fromNodeIndex = try objectReader.readBitLong()
            // 91
            edge.toNodeIndex = try objectReader.readBitLong()
            // 92 x5
            edge.data1 = try objectReader.readBitLong()
            edge.data2 = try objectReader.readBitLong()
            edge.data3 = try objectReader.readBitLong()
            edge.data4 = try objectReader.readBitLong()
            edge.data5 = try objectReader.readBitLong()
            evaluationGraph.edges.append(edge)
            e += 1
        }

        return template
    }

    private func readEvaluationExpression(_ template: ACad.CadTemplate) throws {
        try readCommonNonEntityData(template)
        let expression = template.cadObject as! A.EvaluationExpression

        // AcDbEvalExpr
        expression.unknown = try objectReader.readBitLong()
        // 98
        expression.value98 = try objectReader.readBitLong()
        // 99
        expression.value99 = try objectReader.readBitLong()

        // Code value
        let code = try mergedReaders.readBitShort()
        if code > 0 {
            let groupValue = A.GroupCodeValueType.of(Int(code))
            let value: A.DxfValue
            switch groupValue {
            case .string, .extendedDataString:
                value = .string(try mergedReaders.readVariableText())
            case .int16, .extendedDataInt16:
                value = .int16(try mergedReaders.readBitShort())
            case .double, .extendedDataDouble:
                value = .double(try mergedReaders.readBitDouble())
            case .int32, .int64, .extendedDataInt32:
                value = .int32(try mergedReaders.readBitLong())
            case .point3D:
                value = .point(try mergedReaders.read3BitDouble())
            default:
                let name = "\(groupValue)"
                throw A.DwgError("[EvaluationExpression] Code not implemented \(name.prefix(1).uppercased() + name.dropFirst())")
            }
            expression.evaluatedValue = A.DxfValuePair(code: Int(code), value: value)
        }

        // 90
        expression.id = try objectReader.readBitLong()
    }

    private func readBlockElement(_ template: ACad.CadTemplate) throws {
        try readEvaluationExpression(template)
        let element = template.cadObject as! A.BlockElement
        // 300 name
        element.elementName = try mergedReaders.readVariableText()
        // 98
        element.value98 = try mergedReaders.readBitLong()
        // 99
        element.value99 = try mergedReaders.readBitLong()
        // 1071
        element.value1071 = try mergedReaders.readBitLong()
    }

    private func readBlockParameter(_ template: ACad.CadTemplate) throws {
        try readBlockElement(template)
        let parameter = template.cadObject as! A.BlockParameter
        // 280
        parameter.showProperties = try mergedReaders.readBit()
        // 281
        parameter.chainActions = try mergedReaders.readBit()
    }

    private func readBlock1PtParameter(_ template: ACad.CadTemplate) throws {
        try readBlockParameter(template)
        let parameter = template.cadObject as! A.Block1PtParameter
        // 1010 1020 1030
        parameter.location = try mergedReaders.read3BitDouble()
        parameter.displacementX = try readEvalParameterProperty()
        parameter.displacementY = try readEvalParameterProperty()
        // 93
        parameter.gripId = Int64(try mergedReaders.readBitLong())
    }

    private func readBlock2PtParameter(_ template: ACad.CadTemplate) throws {
        try readBlockParameter(template)
        let parameter = template.cadObject as! A.Block2PtParameter
        // 1010 1020 1030
        parameter.firstPoint = try mergedReaders.read3BitDouble()
        // 1011 1021 1031
        parameter.secondPoint = try mergedReaders.read3BitDouble()
        parameter.firstPointDisplacementX = try readEvalParameterProperty()
        parameter.firstPointDisplacementY = try readEvalParameterProperty()
        parameter.secondPointDisplacementX = try readEvalParameterProperty()
        parameter.secondPointDisplacementY = try readEvalParameterProperty()
        // 91 values
        for _ in 0..<4 { parameter.gripIds.append(Int64(try mergedReaders.readBitLong())) }
        // 177
        parameter.baseLocation = Int32(try mergedReaders.readBitShort())
    }

    private func readBlockAction(_ template: ACad.CadBlockActionTemplate) throws {
        try readBlockElement(template)
        let blockAction = template.cadObject as! A.BlockAction
        // 1010, 1020, 1030
        blockAction.labelPosition = try mergedReaders.read3BitDouble()
        // 71
        let entityCount = try objectReader.readBitLong()
        var i: Int32 = 0
        while i < entityCount {
            template.entityHandles.insert(try handleReference())
            i += 1
        }
        // 70
        let nparameters = try mergedReaders.readBitLong()
        var j: Int32 = 0
        while j < nparameters {
            blockAction.parametersIds.append(try mergedReaders.readBitLong())
            j += 1
        }
    }

    private func readBlockActionBasePt(_ template: ACad.CadBlockActionTemplate) throws {
        try readBlockAction(template)
        let action = template.cadObject as! A.BlockActionBasePt
        action.basePoint = try mergedReaders.read3BitDouble()
        action.updateBaseXConnection = try readEvalConnection()
        action.updateBaseYConnection = try readEvalConnection()
        action.value280 = try mergedReaders.readBit()
        action.value1012 = try mergedReaders.read3BitDouble()
    }

    private func readEvalConnection() throws -> ACad.EvalConnection {
        var connection = A.EvalConnection()
        // 94 95 (I guess 96 97)
        connection.id = try mergedReaders.readBitLong()
        // 303 304 : exposed custom property label
        connection.name = try mergedReaders.readVariableText()
        return connection
    }

    private func readEvalParameterProperty() throws -> ACad.EvalParameterProperty {
        var property = A.EvalParameterProperty()
        // 170 171
        let n = try mergedReaders.readBitShort()
        var j: Int16 = 0
        while j < n {
            property.connections.append(try readEvalConnection())
            j += 1
        }
        return property
    }

    private func readParameterValueSet() throws -> ACad.ParameterValueSet {
        var valueSet = A.ParameterValueSet()
        // 96
        valueSet.type = try mergedReaders.readBitLong()
        // 141
        valueSet.minimum = try mergedReaders.readBitDouble()
        // 142
        valueSet.maximum = try mergedReaders.readBitDouble()
        // 143
        valueSet.increment = try mergedReaders.readBitDouble()
        let numberOfValues = try mergedReaders.readBitShort()
        var i: Int16 = 0
        while i < numberOfValues {
            valueSet.allowedValues.append(try mergedReaders.readBitDouble())
            i += 1
        }
        return valueSet
    }

    // ───────────────────────── Grips ─────────────────────────

    func readBlockGrip(_ grip: ACad.BlockGrip) throws -> ACad.CadTemplate? {
        let template = A.CadTemplate(grip)
        try readBlockGrip(template)
        return template
    }

    private func readBlockGrip(_ template: ACad.CadTemplate) throws {
        try readBlockElement(template)
        let grip = template.cadObject as! A.BlockGrip
        grip.expressionId1 = try mergedReaders.readBitLong()
        grip.expressionId2 = try mergedReaders.readBitLong()
        grip.location = try mergedReaders.read3BitDouble()
        grip.cycling = try mergedReaders.readBit()
        grip.value93 = try mergedReaders.readBitLong()
    }

    func readAlignmentGrip() throws -> ACad.CadTemplate? {
        let grip = A.BlockAlignmentGrip()
        let template = A.CadTemplate(grip)
        try readBlockGrip(template)
        grip.alignmentX = try mergedReaders.readBitDouble()
        grip.alignmentY = try mergedReaders.readBitDouble()
        grip.alignmentZ = try mergedReaders.readBitDouble()
        return template
    }

    func readFlipGrip() throws -> ACad.CadTemplate? {
        let grip = A.BlockFlipGrip()
        let template = A.CadTemplate(grip)
        try readBlockGrip(template)
        grip.flipExpressionId = try mergedReaders.readBitLong()
        grip.directionX = try mergedReaders.readBitDouble()
        grip.directionY = try mergedReaders.readBitDouble()
        grip.directionZ = try mergedReaders.readBitDouble()
        return template
    }

    func readLinearGrip() throws -> ACad.CadTemplate? {
        let grip = A.BlockLinearGrip()
        let template = A.CadTemplate(grip)
        try readBlockGrip(template)
        grip.distanceX = try mergedReaders.readBitDouble()
        grip.distanceY = try mergedReaders.readBitDouble()
        grip.distanceZ = try mergedReaders.readBitDouble()
        return template
    }

    func readBlockGripLocationComponent() throws -> ACad.CadTemplate? {
        let grip = A.BlockGripLocationComponent()
        let template = A.CadTemplate(grip)
        try readEvaluationExpression(template)
        grip.connection = try readEvalConnection()
        return template
    }

    // ───────────────────────── Parameters ─────────────────────────

    func readBlockAlignmentParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockAlignmentParameter()
        let template = A.CadTemplate(parameter)
        try readBlock2PtParameter(template)
        parameter.isPerpendicular = try mergedReaders.readBit()
        return template
    }

    func readBlockBasePointParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockBasePointParameter()
        let template = A.CadTemplate(parameter)
        try readBlock1PtParameter(template)
        parameter.point1011 = try mergedReaders.read3BitDouble()
        parameter.point1012 = try mergedReaders.read3BitDouble()
        return template
    }

    func readBlockFlipParameter() throws -> ACad.CadTemplate? {
        let flip = A.BlockFlipParameter()
        let template = A.CadTemplate(flip)
        try readBlock2PtParameter(template)
        flip.label = try mergedReaders.readVariableText()
        flip.description = try mergedReaders.readVariableText()
        flip.baseStateName = try mergedReaders.readVariableText()
        flip.flippedStateName = try mergedReaders.readVariableText()
        flip.labelPosition = try mergedReaders.read3BitDouble()
        flip.updatedFlipConnection = try readEvalConnection()
        return template
    }

    func readBlockLinearParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockLinearParameter()
        let template = A.CadTemplate(parameter)
        try readBlock2PtParameter(template)
        // 305
        parameter.label = try mergedReaders.readVariableText()
        // 306
        parameter.description = try mergedReaders.readVariableText()
        // 140
        parameter.labelOffset = try mergedReaders.readBitDouble()
        parameter.valueSet = try readParameterValueSet()
        return template
    }

    func readBlockLookupParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockLookupParameter()
        let template = A.CadTemplate(parameter)
        try readBlock1PtParameter(template)
        parameter.actionId = try mergedReaders.readBitLong()
        parameter.label = try mergedReaders.readVariableText()
        parameter.description = try mergedReaders.readVariableText()
        return template
    }

    func readBlockPointParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockPointParameter()
        let template = A.CadTemplate(parameter)
        try readBlock1PtParameter(template)
        parameter.label = try mergedReaders.readVariableText()
        parameter.description = try mergedReaders.readVariableText()
        parameter.labelPosition = try mergedReaders.read3BitDouble()
        return template
    }

    func readBlockPolarParameter() throws -> ACad.CadTemplate? {
        let polar = A.BlockPolarParameter()
        let template = A.CadTemplate(polar)
        try readBlock2PtParameter(template)
        polar.label = try mergedReaders.readVariableText()
        polar.description = try mergedReaders.readVariableText()
        polar.angleName = try mergedReaders.readVariableText()
        polar.angleDescription = try mergedReaders.readVariableText()
        polar.labelOffset = try mergedReaders.readBitDouble()
        polar.distanceValueSet = try readParameterValueSet()
        polar.angleValueSet = try readParameterValueSet()
        return template
    }

    func readBlockRotationParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockRotationParameter()
        let template = A.CadTemplate(parameter)
        try readBlock2PtParameter(template)
        // 1011 1021 1031
        parameter.point = try mergedReaders.read3BitDouble()
        // 305
        parameter.label = try mergedReaders.readVariableText()
        // 306
        parameter.description = try mergedReaders.readVariableText()
        // 140
        parameter.labelOffset = try mergedReaders.readBitDouble()
        parameter.valueSet = try readParameterValueSet()
        return template
    }

    func readBlockXYParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockXYParameter()
        let template = A.CadTemplate(parameter)
        try readBlock2PtParameter(template)
        parameter.labelY = try mergedReaders.readVariableText()
        parameter.labelX = try mergedReaders.readVariableText()
        parameter.descriptionY = try mergedReaders.readVariableText()
        parameter.descriptionX = try mergedReaders.readVariableText()
        parameter.labelOffsetX = try mergedReaders.readBitDouble()
        parameter.labelOffsetY = try mergedReaders.readBitDouble()
        parameter.valueSetX = try readParameterValueSet()
        parameter.valueSetY = try readParameterValueSet()
        return template
    }

    func readBlockVisibilityParameter() throws -> ACad.CadTemplate? {
        let parameter = A.BlockVisibilityParameter()
        let template = A.CadBlockVisibilityParameterTemplate(parameter)
        try readBlock1PtParameter(template)
        // 281
        parameter.chainActions = try mergedReaders.readBit()
        // 301
        parameter.label = try mergedReaders.readVariableText()
        // 302
        parameter.description = try mergedReaders.readVariableText()
        // missing bit?? 91 should be an int
        parameter.value91 = try mergedReaders.readBit()

        // DXF 93 Total entities count
        let totalEntitiesCount = try objectReader.readBitLong()
        var i: Int32 = 0
        while i < totalEntitiesCount {
            // 331
            template.entityHandles.append(try handleReference())
            i += 1
        }

        // DXF 92 states count
        let nstates = try objectReader.readBitLong()
        var j: Int32 = 0
        while j < nstates {
            template.stateTemplates.append(try readState())
            j += 1
        }
        return template
    }

    private func readState() throws -> ACad.CadBlockVisibilityParameterTemplate.StateTemplate {
        let template = A.CadBlockVisibilityParameterTemplate.StateTemplate()
        template.state.name = try textReader.readVariableText()
        // DXF 94 subset count 1
        let n1 = try objectReader.readBitLong()
        var i: Int32 = 0
        while i < n1 {
            // 332
            template.entityHandles.insert(try handleReference())
            i += 1
        }
        // DXF 95 subset count 2
        let n2 = try objectReader.readBitLong()
        var j: Int32 = 0
        while j < n2 {
            // 333
            template.expressionHandles.insert(try handleReference())
            j += 1
        }
        return template
    }

    // ───────────────────────── Actions ─────────────────────────

    func readBlockArrayAction() throws -> ACad.CadTemplate? {
        let array = A.BlockArrayAction()
        let template = A.CadBlockActionTemplate(array)
        try readBlockAction(template)
        array.baseConnection = try readEvalConnection()
        array.endConnection = try readEvalConnection()
        array.updatedBaseConnection = try readEvalConnection()
        array.updatedEndConnection = try readEvalConnection()
        array.rowOffset = try mergedReaders.readBitDouble()
        array.columnOffset = try mergedReaders.readBitDouble()
        return template
    }

    func readBlockFlipAction() throws -> ACad.CadTemplate? {
        let flipAction = A.BlockFlipAction()
        let template = A.CadBlockActionTemplate(flipAction)
        try readBlockAction(template)
        flipAction.flipConnection = try readEvalConnection()
        flipAction.updatedFlipConnection = try readEvalConnection()
        flipAction.updatedBaseConnection = try readEvalConnection()
        flipAction.updatedEndConnection = try readEvalConnection()
        return template
    }

    func readBlockLookupAction() throws -> ACad.CadTemplate? {
        let lookupAction = A.BlockLookupAction()
        let template = A.CadBlockLookupActionTemplate(lookupAction)
        try readBlockAction(template)

        let rows = try mergedReaders.readBitLong()
        let columns = try mergedReaders.readBitLong()
        template.numberOfRows = rows
        template.numberOfColumns = columns

        // `i < NumberOfRows * NumberOfColumns` (unchecked int multiplication)
        let cells = rows &* columns
        var i: Int32 = 0
        while i < cells {
            template.rowValues.append(try mergedReaders.readVariableText())
            i += 1
        }
        var j: Int32 = 0
        while j < columns {
            lookupAction.columns.append(try readLookupActionColumn())
            j += 1
        }
        lookupAction.unknownFlag = try mergedReaders.readBit()
        return template
    }

    private func readLookupActionColumn() throws -> ACad.BlockLookupAction.ColumnData {
        let column = A.BlockLookupAction.ColumnData()
        column.nodeId = try mergedReaders.readBitLong()
        column.valueType = try mergedReaders.readBitLong()
        column.type = try mergedReaders.readBitLong()
        column.isLookupProperty = try mergedReaders.readBit()
        column.unmatchedName = try mergedReaders.readVariableText()
        column.isReadOnly = !(try mergedReaders.readBit())
        column.connectionName = try mergedReaders.readVariableText()
        return column
    }

    func readBlockMoveAction() throws -> ACad.CadTemplate? {
        let moveAction = A.BlockMoveAction()
        let template = A.CadBlockActionTemplate(moveAction)
        try readBlockAction(template)
        moveAction.xDeltaConnection = try readEvalConnection()
        moveAction.yDeltaConnection = try readEvalConnection()
        moveAction.distanceMultiplier = try mergedReaders.readBitDouble()
        moveAction.angleOffset = try mergedReaders.readBitDouble()
        moveAction.unknownFlag = try mergedReaders.readByte()
        return template
    }

    func readBlockRotateAction() throws -> ACad.CadTemplate? {
        let rotationAction = A.BlockRotationAction()
        let template = A.CadBlockActionTemplate(rotationAction)
        try readBlockActionBasePt(template)
        rotationAction.angleDeltaConnection = try readEvalConnection()
        return template
    }

    func readBlockScaleAction() throws -> ACad.CadTemplate? {
        let scaleAction = A.BlockScaleAction()
        let template = A.CadBlockActionTemplate(scaleAction)
        try readBlockActionBasePt(template)
        scaleAction.scaleConnection = try readEvalConnection()
        scaleAction.xScaleConnection = try readEvalConnection()
        scaleAction.yScaleConnection = try readEvalConnection()
        scaleAction.scaleType = try mergedReaders.readByte()
        return template
    }

    /// The boundary, bindings and stretch nodes both stretch actions share.
    private func readStretchData(_ template: ACad.CadStretchActionBaseTemplate, selection: ((ACad.CadStretchActionBaseTemplate) throws -> Void)?) throws {
        let action = template.cadObject as! A.StretchActionBase
        let npts = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < npts {
            action.boundary.append(try mergedReaders.read2RawDouble())
            i += 1
        }
        try selection?(template)
        let nbindings = try mergedReaders.readBitLong()
        var b: Int32 = 0
        while b < nbindings {
            let h = try handleReference()
            var indexes: [Int32] = []
            let nindexes = try mergedReaders.readBitLong()
            var j: Int32 = 0
            while j < nindexes {
                indexes.append(try mergedReaders.readBitLong())
                j += 1
            }
            try template.addBinding(h, indexes)
            b += 1
        }
        let nnodes = try mergedReaders.readBitLong()
        var n: Int32 = 0
        while n < nnodes {
            let nodeId = try mergedReaders.readBitLong()
            let nindexes = try mergedReaders.readBitLong()
            var indexes: [Int32] = []
            var j: Int32 = 0
            while j < nindexes {
                indexes.append(try mergedReaders.readBitLong())
                j += 1
            }
            action.stretchNodes.append(A.StretchNode(nodeId: nodeId, pointIndexes: indexes))
            n += 1
        }
        action.distanceMultiplier = try mergedReaders.readBitDouble()
        action.angleOffset = try mergedReaders.readBitDouble()
    }

    func readBlockPolarStretchAction() throws -> ACad.CadTemplate? {
        let stretchAction = A.BlockPolarStretchAction()
        let template = A.CadPolarStretchActionTemplate(stretchAction)
        try readBlockAction(template)
        stretchAction.baseXDeltaConnection = try readEvalConnection()
        stretchAction.baseYDeltaConnection = try readEvalConnection()
        stretchAction.baseConnection = try readEvalConnection()
        stretchAction.endConnection = try readEvalConnection()
        stretchAction.updatedBaseConnection = try readEvalConnection()
        stretchAction.updatedEndConnection = try readEvalConnection()
        try readStretchData(template) { t in
            let polar = t as! A.CadPolarStretchActionTemplate
            let selection = try self.mergedReaders.readBitLong()
            var j: Int32 = 0
            while j < selection {
                polar.selectionHandles.append(try self.handleReference())
                j += 1
            }
        }
        let unknown = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < unknown {
            _ = try mergedReaders.readBitLong()
            i += 1
        }
        return template
    }

    func readBlockStretchAction() throws -> ACad.CadTemplate? {
        let stretchAction = A.BlockStretchAction()
        let template = A.CadStretchActionBaseTemplate(stretchAction)
        try readBlockAction(template)
        stretchAction.endXDeltaConnection = try readEvalConnection()
        stretchAction.endYDeltaConnection = try readEvalConnection()
        try readStretchData(template, selection: nil)
        stretchAction.unknownFlag = try mergedReaders.readByte()
        return template
    }

    // ───────────────────────── Block data ─────────────────────────

    func readBlockRepresentationData() throws -> ACad.CadTemplate? {
        let representation = A.BlockRepresentationData()
        let template = A.CadBlockRepresentationDataTemplate(representation)
        try readCommonNonEntityData(template)
        representation.version = try mergedReaders.readBitShort()
        template.blockHandle = try handleReference()
        return template
    }

    func readDynamicBlockPurgePreventer() throws -> ACad.CadTemplate? {
        let purgePreventer = A.DynamicBlockPurgePreventer()
        let template = A.DynamicBlockPurgePreventerTemplate(purgePreventer)
        try readCommonNonEntityData(template)
        purgePreventer.version = try mergedReaders.readBitShort()
        template.blockHandle = try handleReference()
        return template
    }

    // ───────────────────────── Fields ─────────────────────────

    func readField() throws -> ACad.CadTemplate? {
        let field = A.Field()
        let template = A.CadFieldTemplate(field)

        try readCommonNonEntityData(template)

        // TV 1 Evaluator ID, TV 2,3 Field code
        field.evaluatorId = try mergedReaders.readVariableText()
        field.fieldCode = try mergedReaders.readVariableText()
        // BL 90 Number of child fields
        let nchild = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < nchild {
            // H 360 Child field handle (hard owner)
            template.childrenHandles.append(try handleReference())
            i += 1
        }
        // BL 97 Number of field objects
        let nfields = try mergedReaders.readBitLong()
        var j: Int32 = 0
        while j < nfields {
            // H 331 Field object handle (soft pointer)
            template.cadObjectsHandles.append(try handleReference())
            j += 1
        }
        // -R2004: TV 4 Format string
        if version < .ac1021 {
            field.formatString = try mergedReaders.readVariableText()
        }
        // BL 91 Evaluation option flags
        field.evaluationOptionFlags = try mergedReaders.readBitLong()
        // BL 92 Filing option flags
        field.filingOptionFlags = try mergedReaders.readBitLong()
        // BL 94 Field state flags
        field.fieldStateFlags = try mergedReaders.readBitLong()
        // BL 95 Evaluation status flags
        field.evaluationStatusFlags = try mergedReaders.readBitLong()
        // BL 96 Evaluation error code
        field.evaluationErrorCode = try mergedReaders.readBitLong()
        // TV 300 Evaluation error message
        field.evaluationErrorMessage = try mergedReaders.readVariableText()
        // The field value
        template.cadValueTemplates.append(try readCadValue(field.value))
        // TV 301,9 Value string
        field.formatString = try mergedReaders.readVariableText()
        _ = try mergedReaders.readBitLong()
        let num3 = try mergedReaders.readBitLong()
        var k: Int32 = 0
        while k < num3 {
            // TV 6 Child field key
            let key = try mergedReaders.readVariableText()
            let value = A.CadValue()
            template.cadValueTemplates.append(try readCadValue(value))
            // `Dictionary.Add`
            guard field.values.add(key, value) else { throw A.DwgError.duplicateKey(key) }
            k += 1
        }
        return template
    }

    func readFieldList() throws -> ACad.CadTemplate? {
        let fieldList = A.FieldList()
        let template = A.CadFieldListTemplate(fieldList)
        try readCommonNonEntityData(template)
        // BL Number of fields
        let nhandles = try mergedReaders.readBitLong()
        // B Unknown
        _ = try mergedReaders.readBit()
        var i: Int32 = 0
        while i < nhandles {
            // H 330 Field handle (soft pointer)
            template.ownedObjectsHandlers.insert(try handleReference())
            i += 1
        }
        return template
    }

    /// `readCadValue`.
    func readCadValue(_ value: ACad.CadValue) throws -> ACad.CadValueTemplate {
        let template = A.CadValueTemplate(value)

        // R2007+: Flags BL 93
        if r2007Plus {
            value.flags = try mergedReaders.readBitLong()
        }
        // Data type BL 90
        value.valueType = try mergedReaders.readBitLong()
        if !r2007Plus || !value.isEmpty {
            switch value.valueType {
            case A.CadValueType.unknown, A.CadValueType.long:
                try value.setValue(.int(try mergedReaders.readBitLong()))
            case A.CadValueType.double:
                try value.setValue(.double(try mergedReaders.readBitDouble()))
            case A.CadValueType.general, A.CadValueType.string:
                try value.setValue(.string(try readStringCadValue()))
            case A.CadValueType.date:
                if let date = try readDateCadValue() { try value.setValue(.date(date)) }
            case A.CadValueType.point2D:
                // A missing vector is null, which SetValue rejects.
                guard let xy = try readValueXY() else { throw A.CadValue.InvalidValue() }
                try value.setValue(.point2D(xy))
            case A.CadValueType.point3D:
                guard let xyz = try readValueXYZ() else { throw A.CadValue.InvalidValue() }
                try value.setValue(.point3D(xyz))
            case A.CadValueType.handle:
                template.valueHandle = try handleReference()
            default:
                throw A.DwgError.notImplemented
            }
        }
        // R2007+:
        if r2007Plus {
            // Unit type BL 94
            value.units = try mergedReaders.readBitLong()
            // Format String TV 300
            value.format = try mergedReaders.readVariableText()
            // Value String TV 302
            value.formattedValue = try mergedReaders.readVariableText()
        }
        return template
    }

    // ───────────────────────── Object context data ─────────────────────────

    func readObjectContextData(_ template: ACad.CadTemplate) throws {
        try readCommonNonEntityData(template)
        let contextData = template.cadObject as! A.ObjectContextData
        // BS 70 Version (default value is 3).
        contextData.version = try objectReader.readBitShort()
        // B 290 Default flag (default value is false).
        contextData.default = try objectReader.readBit()
    }

    private func readAnnotScaleObjectContextData(_ template: ACad.CadAnnotScaleObjectContextDataTemplate) throws {
        try readObjectContextData(template)
        template.scaleHandle = try handleReference()
    }

    func readBlkRefObjectContextData() throws -> ACad.CadTemplate? {
        let contextData = A.BlockReferenceObjectContextData()
        let template = A.CadAnnotScaleObjectContextDataTemplate(contextData)
        try readAnnotScaleObjectContextData(template)
        contextData.rotation = try mergedReaders.readBitDouble()
        contextData.insertionPoint = try mergedReaders.read3BitDouble()
        contextData.xScale = try mergedReaders.readBitDouble()
        contextData.yScale = try mergedReaders.readBitDouble()
        contextData.zScale = try mergedReaders.readBitDouble()
        return template
    }

    /// Not read by ACadSharp 3.8.0 (a TODO there): the object ends up as an UnknownNonGraphicalObject.
    func readMTextAttributeObjectContextData() throws -> ACad.CadTemplate? { nil }

    // ───────────────────────── Dimension associativity ─────────────────────────

    func readDimensionAssociation() throws -> ACad.CadTemplate? {
        let association = A.DimensionAssociation()
        let template = A.CadDimensionAssociationTemplate(association)

        try readCommonNonEntityData(template)

        // 330
        template.dimensionHandle = try handleReference()
        // 90
        association.associativityFlags = Int16(truncatingIfNeeded: try mergedReaders.readBitLong())
        // 70
        association.isTransSpace = try mergedReaders.readBit()
        // 71
        association.rotatedDimensionType = Int16(try mergedReaders.readByte())

        // The template assigns the point references when it is built; nothing reads them before.
        typealias F = A.DimensionAssociation.Flags
        if association.associativityFlags & F.firstPointReference != 0 {
            association.firstPointRef = try readOsnapPointRef(template)
        }
        if association.associativityFlags & F.secondPointReference != 0 {
            association.secondPointRef = try readOsnapPointRef(template)
        }
        if association.associativityFlags & F.thirdPointReference != 0 {
            association.thirdPointRef = try readOsnapPointRef(template)
        }
        if association.associativityFlags & F.fourthPointReference != 0 {
            association.fourthPointRef = try readOsnapPointRef(template)
        }
        return template
    }

    private func readOsnapPointRef(_ owner: ACad.CadDimensionAssociationTemplate) throws -> ACad.DimensionAssociation.OsnapPointRef {
        let osnap = A.DimensionAssociation.OsnapPointRef()
        let template = A.CadDimensionAssociationTemplate.OsnapPointRefTemplate(osnap)
        // 1
        _ = try mergedReaders.readVariableText()
        // 72
        osnap.objectOsnapType = Int16(try mergedReaders.readByte())
        // 331
        template.objectHandle = try handleReference()
        owner.pointRefTemplates.append(template)
        return osnap
    }

    /// `read4x3Matrix`: the 12 values row by row (`identity[i, j]`, i < 3, j < 4).
    func read4x3Matrix() throws -> [Double] {
        var values: [Double] = []
        for _ in 0..<12 { values.append(try mergedReaders.readBitDouble()) }
        return values
    }

    // ───────────────────────── AEC ─────────────────────────

    func readAecWall() throws -> ACad.CadTemplate? {
        let wall = A.Wall()
        let template = A.CadWallTemplate(wall)

        try readCommonEntityData(template)

        // Version information (common in AEC objects)
        if r2000Plus {
            wall.version = try mergedReaders.readBitLong()
        }

        // Read standard handles
        _ = try handleReference() // skip 0 handle
        template.styleHandle = try handleReference() // Should be AEC_WALL_STYLE
        template.cleanupGroupHandle = try handleReference() // Should be AEC_CLEANUP_GROUP_DEF

        let objectPos = objectReader.positionInBits()
        let handlesPos = handlesReader.positionInBits()
        let objectDataSize = handlesPos - objectPos

        // Store raw proprietary data
        if objectDataSize > 0 {
            var dataBytes = Int(Int32(truncatingIfNeeded: objectDataSize / 8))
            if objectDataSize % 8 != 0 { dataBytes += 1 }
            template.rawData = try objectReader.readBytes(dataBytes)
        }
        return template
    }

    /// The bits left in the object after the current position (`_objectInitialPos + _size * 8`, uint arithmetic).
    private func remainingObjectBytes() -> Int {
        let endPos = objectInitialPos + Int(UInt32(truncatingIfNeeded: UInt64(size) &* 8))
        let remainingBits = endPos - mergedReaders.positionInBits()
        return remainingBits > 0 ? Int(Int32(truncatingIfNeeded: remainingBits / 8)) : 0
    }

    func readAecWallStyle() throws -> ACad.CadTemplate? {
        let wallStyle = A.AecWallStyle()
        let template = A.CadNonGraphicalObjectTemplate(wallStyle)

        try readCommonNonEntityData(template)

        if r2000Plus {
            wallStyle.version = try mergedReaders.readBitLong()
        }
        // Description field (common in AEC style objects)
        wallStyle.description = try mergedReaders.readVariableText()

        let remainingBytes = remainingObjectBytes()
        if remainingBytes > 0 {
            wallStyle.rawData = try mergedReaders.readBytes(remainingBytes)
        }
        return template
    }

    func readAecCleanupGroup() throws -> ACad.CadTemplate? {
        let cleanupGroup = A.AecCleanupGroup()
        let template = A.CadNonGraphicalObjectTemplate(cleanupGroup)

        try readCommonNonEntityData(template)

        do {
            if r2000Plus {
                cleanupGroup.version = try mergedReaders.readBitLong()
            }
            cleanupGroup.description = try mergedReaders.readVariableText()
            let remainingBytes = remainingObjectBytes()
            if remainingBytes > 0 {
                cleanupGroup.rawData = try mergedReaders.readBytes(remainingBytes)
            }
        } catch {
            builder.notify("Error reading AEC_CLEANUP_GROUP [Handle: \(String(cleanupGroup.handle, radix: 16, uppercase: true))]: \(error)")
        }
        return template
    }

    // ───────────────────────── AutoCAD Mechanical ─────────────────────────

    /// `readMechanicalEntity`.
    private func readMechanicalEntity(_ template: ACad.CadEntityTemplate) throws {
        _ = try mergedReaders.readBitLong() // 212
        (template.cadObject as! A.MechanicalEntity).position = try mergedReaders.read3BitDouble()
        // StandardDINHandle, BOMStandardDINHandle (kept by nothing)
        _ = try handleReference()
        _ = try handleReference()
    }

    func readAcmPartRef() throws -> ACad.CadTemplate? {
        let template = A.CadEntityTemplate(A.AcmPartRef())
        try readCommonEntityData(template)
        try readMechanicalEntity(template)
        _ = try handleReference() // LineResHandle
        _ = try handleReference() // UnknownHandle1, 0x0
        _ = try handleReference() // DataEntryPartHandle
        template.layerHandle = try handleReference()
        return template
    }

    func readAcmPartList() throws -> ACad.CadTemplate? {
        let template = A.CadEntityTemplate(A.AcmPartList())
        try readCommonEntityData(template)
        try readMechanicalEntity(template)
        _ = try handleReference() // BomHandle: ACMBOM:*A1 (AcmBom)
        _ = try handleReference() // ItemFilterCustomHandle
        // Handles to each data row (excluding the headers) of the BOM table, up to a null handle.
        while try handleReference() != 0 {}
        _ = try handleReference() // UnknownHandle1, 0x0
        _ = try handleReference() // UnknownHandle2, 0x0
        return template
    }

    func readAcmBalloon() throws -> ACad.CadTemplate? {
        let balloon = A.AcmBalloon()
        let template = A.CadAcmBalloonTemplate(balloon)
        try readCommonEntityData(template)
        try readMechanicalEntity(template)
        _ = try mergedReaders.read3BitDouble() // unknown position 1
        _ = try mergedReaders.read3BitDouble() // unknown position 2
        _ = try handleReference() // BomRowHandle
        template.blockHandle = try handleReference()
        _ = try handleReference() // unknown, 0x0
        return template
    }
}
