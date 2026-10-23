// DXF readers (ACadSharp DxfObjectsSectionReader) for dynamic block objects, dimension associativity, block
// representation data, geographic data, fields, proxy objects and annotation-scale context data, with their
// templates. The `assign…` functions are the reflection maps of ACadSharp (`tryAssignCurrentValue` with one
// subclass map): only the codes of that subclass, with .NET's value conversions.

import Foundation

extension ACad {
    // ───────────────────────── Templates ─────────────────────────

    final class CadEvaluationGraphTemplate: CadTemplate {
        var nodeTemplates: [(node: EvaluationGraph.Node, expressionHandle: UInt64?)] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            for (node, handle) in nodeTemplates {
                if let expression: EvaluationExpression = builder.tryGetObject(handle) {
                    node.setExpression(expression)
                } else {
                    builder.notify("Evaluation graph couldn't find the EvaluationExpression with handle \(handle.map(String.init) ?? "")")
                }
            }
        }
    }

    class CadBlockActionTemplate: CadTemplate {
        var entityHandles = HandleSet()

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let action = cadObject as! BlockAction
            for handle in entityHandles {
                if let entity: Entity = builder.tryGetObject(handle) {
                    action.entities.append(entity)
                } else {
                    builder.notify("[\(action.debugName)] entity with handle \(handle) not found.")
                }
            }
        }
    }

    class CadStretchActionBaseTemplate: CadBlockActionTemplate {
        /// `Dictionary<ulong, StretchEntityBind>`: a repeated handle fails the object like Dictionary.Add.
        var bindings: [(handle: UInt64, pointIndexes: [Int32])] = []

        func addBinding(_ handle: UInt64, _ indexes: [Int32]) throws {
            if bindings.contains(where: { $0.handle == handle }) {
                throw DxfException("An item with the same key has already been added. Key: \(handle)")
            }
            bindings.append((handle, indexes))
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let action = cadObject as! StretchActionBase
            for (handle, indexes) in bindings {
                if let entity: Entity = builder.tryGetObject(handle) {
                    action.stretchBindings.append(StretchEntityBind(entity: entity, pointIndexes: indexes))
                } else {
                    builder.notify("[\(action.debugName)] entity with handle \(handle) not found.")
                }
            }
        }
    }

    final class CadPolarStretchActionTemplate: CadStretchActionBaseTemplate {
        var selectionHandles: [UInt64] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let action = cadObject as! BlockPolarStretchAction
            for handle in selectionHandles {
                if let entity: Entity = builder.tryGetObject(handle) {
                    action.rotateBindings.append(entity)
                } else {
                    builder.notify("[\(action.debugName)] entity with handle \(handle) not found.")
                }
            }
        }
    }

    final class CadBlockLookupActionTemplate: CadBlockActionTemplate {
        var numberOfRows: Int32?
        var numberOfColumns: Int32?
        var rowValues: [String] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let action = cadObject as! BlockLookupAction
            guard let rows = numberOfRows, let columns = numberOfColumns else { return }
            for i in 0..<Int(max(rows, 0)) {
                for j in 0..<Int(max(columns, 0)) {
                    // ACadSharp indexes without checks: missing columns or rows fail the build.
                    guard j < action.columns.count, i * Int(columns) + j < rowValues.count else {
                        builder.fail("Index was out of range. Must be non-negative and less than the size of the collection. (Parameter 'index')")
                        return
                    }
                    action.columns[j].rows.append(rowValues[i * Int(columns) + j])
                }
            }
        }
    }

    final class CadBlockVisibilityParameterTemplate: CadTemplate {
        final class StateTemplate {
            let state = BlockVisibilityParameter.State()
            var entityHandles = HandleSet()
            var expressionHandles = HandleSet()

            func build(_ builder: CadDocumentBuilder, parentEntities: [UInt64]) {
                for handle in entityHandles {
                    if !parentEntities.contains(handle) {
                        builder.notify("[\(state)] parent does not contain handle \(handle).")
                    }
                    if let entity: Entity = builder.tryGetObject(handle) {
                        state.entities.append(entity)
                    } else {
                        builder.notify("[\(state)] \(Entity.self) with handle \(handle) not found.")
                    }
                }
                for handle in expressionHandles {
                    if let expression: EvaluationExpression = builder.tryGetObject(handle) {
                        state.expressions.append(expression)
                    } else {
                        builder.notify("[\(state)] \(EvaluationExpression.self) with handle \(handle) not found.")
                    }
                }
            }
        }

        var entityHandles: [UInt64] = []
        var stateTemplates: [StateTemplate] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let parameter = cadObject as! BlockVisibilityParameter
            for handle in entityHandles {
                if let entity: Entity = builder.tryGetObject(handle) {
                    parameter.entities.append(entity)
                } else {
                    builder.notify("[\(parameter.debugName)] entity with handle \(handle) not found.")
                }
            }
            for template in stateTemplates {
                template.build(builder, parentEntities: entityHandles)
                if !parameter.addState(template.state) {
                    builder.fail("An item with the same key has already been added. Key: \(template.state.name ?? "")")
                    return
                }
            }
        }
    }

    final class CadDimensionAssociationTemplate: CadTemplate {
        final class OsnapPointRefTemplate {
            let pointRef: DimensionAssociation.OsnapPointRef
            var objectHandle: UInt64?
            init(_ pointRef: DimensionAssociation.OsnapPointRef) { self.pointRef = pointRef }

            func build(_ builder: CadDocumentBuilder) {
                if let object: CadObject = builder.tryGetObject(objectHandle) { pointRef.geometry = object }
            }
        }

        var dimensionHandle: UInt64?
        var pointRefTemplates: [OsnapPointRefTemplate] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let association = cadObject as! DimensionAssociation
            if let dimension: Dimension = builder.tryGetObject(dimensionHandle) { association.dimension = dimension }
            // ACadSharp's reader keeps the point references on the object, the templates only resolve geometry.
            for template in pointRefTemplates { template.build(builder) }
        }
    }

    final class CadBlockRepresentationDataTemplate: CadTemplate {
        var blockHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let record: BlockRecord = tableReference(builder, blockHandle, nil) {
                (cadObject as! BlockRepresentationData).block = record
            }
        }
    }

    final class CadValueTemplate {
        let value: CadValue
        var valueHandle: UInt64?
        init(_ value: CadValue) { self.value = value }

        func build(_ builder: CadDocumentBuilder) {
            if let object: CadObject = builder.tryGetObject(valueHandle) {
                do {
                    try value.setValue(.object(object), type: CadValueType.handle)
                } catch {
                    builder.fail("\(error)")
                }
            }
        }
    }

    final class CadFieldTemplate: CadTemplate {
        var cadObjectsHandles: [UInt64] = []
        var cadValueTemplates: [CadValueTemplate] = []
        var childrenHandles: [UInt64] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let field = cadObject as! Field
            for handle in cadObjectsHandles {
                if let object: CadObject = builder.tryGetObject(handle) {
                    field.cadObjects.append(object)
                } else {
                    builder.notify("[\(field.subclassMarker)] CadObject with handle \(handle) not found.")
                }
            }
            for handle in childrenHandles {
                if let child: Field = builder.tryGetObject(handle) {
                    field.children.add(child)
                } else {
                    builder.notify("[\(field.subclassMarker)] CadObject with handle \(handle) not found.")
                }
            }
        }
    }

    final class CadFieldListTemplate: CadTemplate {
        var ownedObjectsHandlers = HandleSet()

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let list = cadObject as! FieldList
            for handle in ownedObjectsHandlers {
                if let field: Field = builder.tryGetObject(handle) {
                    list.fields.append(field)
                } else {
                    builder.notify("Field \(handle) not found for FieldList \(list.handle)")
                }
            }
        }
    }

    final class CadProxyObjectTemplate: CadTemplate {
        var entries: [UInt64] = []
    }

    final class CadAnnotScaleObjectContextDataTemplate: CadTemplate {
        var scaleHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let scale: Scale = builder.tryGetObject(scaleHandle) {
                (cadObject as! AnnotScaleObjectContextData).scale = scale
            }
        }
    }
}

extension ACad.DxfReader {
    typealias A = ACad

    /// The object readers of this file, by DXF name.
    func readEvaluationObject(_ name: String) throws -> ACad.CadTemplate?? {
        typealias T = ACad.DxfFileToken
        switch name {
        case T.blkRefObjectContextData:
            let t = A.CadAnnotScaleObjectContextDataTemplate(A.BlockReferenceObjectContextData())
            return try readObjectCodes(t) { try self.readAnnotScaleObjectContextData(t) }
        case T.mTextAttributeObjectContextData:
            let t = A.CadAnnotScaleObjectContextDataTemplate(A.MTextAttributeObjectContextData())
            return try readObjectCodes(t) { try self.readAnnotScaleObjectContextData(t) }
        case T.objectDimensionAssociation:
            let t = A.CadDimensionAssociationTemplate(A.DimensionAssociation())
            return try readObjectCodes(t) { try self.readDimensionAssociation(t) }
        case T.objectEvalGraph:
            let t = A.CadEvaluationGraphTemplate(A.EvaluationGraph())
            return try readObjectCodes(t) { try self.readEvaluationGraph(t) }
        case T.objectProxyObject:
            let t = A.CadProxyObjectTemplate(A.ProxyObject())
            return try readObjectCodes(t) { try self.readProxyObject(t) }
        case T.objectGeoData:
            let t = A.CadTemplate(A.GeoData())
            return try readObjectCodes(t) { try self.readGeoData(t) }
        case T.objectDynamicBlockPurgePreventer:
            let t = A.CadNonGraphicalObjectTemplate(A.DynamicBlockPurgePreventer())
            return try readObjectCodes(t) { try self.readObjectSubclassMap(t) }
        case T.objectBlockRepresentationData:
            let t = A.CadBlockRepresentationDataTemplate(A.BlockRepresentationData())
            return try readObjectCodes(t) {
                if self.reader.code == 340 {
                    t.blockHandle = try self.reader.valueAsHandle
                    return true
                }
                return try self.assign(t.cadObject, subclassMap: t.cadObject.subclassMarker)
            }
        case T.objectBlockBasePointParameter:
            let t = A.CadTemplate(A.BlockBasePointParameter())
            return try readObjectCodes(t) { try self.readSubclass(t, A.DxfSubclassMarker.blockBasePointParameter, then: self.readBlock1PtParameter) }
        case T.objectBlockGripLocationComponent:
            let t = A.CadTemplate(A.BlockGripLocationComponent())
            return try readObjectCodes(t) { try self.readBlockGripLocationComponent(t) }
        case T.objectBlockVisibilityGrip, T.objectBlockXYGrip, T.objectBlockFlipGrip, T.objectBlockLinearGrip,
             T.objectBlockLookupGrip, T.objectBlockRotationGrip, T.objectBlockPolarGrip, T.objectBlockAlignmentGrip:
            let grip: A.BlockGrip
            switch name {
            case T.objectBlockVisibilityGrip: grip = A.BlockVisibilityGrip()
            case T.objectBlockXYGrip: grip = A.BlockXYGrip()
            case T.objectBlockFlipGrip: grip = A.BlockFlipGrip()
            case T.objectBlockLinearGrip: grip = A.BlockLinearGrip()
            case T.objectBlockLookupGrip: grip = A.BlockLookupGrip()
            case T.objectBlockRotationGrip: grip = A.BlockRotationGrip()
            case T.objectBlockPolarGrip: grip = A.BlockPolarGrip()
            default: grip = A.BlockAlignmentGrip()
            }
            let t = A.CadTemplate(grip)
            return try readObjectCodes(t) {
                // readBlockGripSubclass: the current subclass map, then the grip's.
                if try self.assignCurrent(t.cadObject) { return true }
                return try self.readBlockGrip(t)
            }
        case T.objectBlockVisibilityParameter:
            let t = A.CadBlockVisibilityParameterTemplate(A.BlockVisibilityParameter())
            return try readObjectCodes(t) { try self.readBlockVisibilityParameter(t) }
        case T.objectBlockPolarParameter:
            let t = A.CadTemplate(A.BlockPolarParameter())
            return try readObjectCodes(t) { try self.readBlockPolarParameter(t) }
        case T.objectBlockRotationParameter:
            let t = A.CadTemplate(A.BlockRotationParameter())
            return try readObjectCodes(t) { try self.readBlockRotationParameter(t) }
        case T.objectBlockLinearParameter:
            let t = A.CadTemplate(A.BlockLinearParameter())
            return try readObjectCodes(t) { try self.readBlockLinearParameter(t) }
        case T.objectBlockLookupParameter:
            let t = A.CadTemplate(A.BlockLookupParameter())
            return try readObjectCodes(t) { try self.readSubclass(t, A.DxfSubclassMarker.blockLookupParameter, then: self.readBlock1PtParameter) }
        case T.objectBlockAlignmentParameter:
            let t = A.CadTemplate(A.BlockAlignmentParameter())
            return try readObjectCodes(t) { try self.readSubclass(t, A.DxfSubclassMarker.blockAlignmentParameter, then: self.readBlock2PtParameter) }
        case T.objectBlockFlipParameter:
            let t = A.CadTemplate(A.BlockFlipParameter())
            return try readObjectCodes(t) { try self.readBlockFlipParameter(t) }
        case T.objectBlockPointParameter:
            let t = A.CadTemplate(A.BlockPointParameter())
            return try readObjectCodes(t) { try self.readSubclass(t, A.DxfSubclassMarker.blockPointParameter, then: self.readBlock1PtParameter) }
        case T.objectBlockXYParameter:
            let t = A.CadTemplate(A.BlockXYParameter())
            return try readObjectCodes(t) { try self.readBlockXYParameter(t) }
        case T.objectBlockLookupAction:
            let t = A.CadBlockLookupActionTemplate(A.BlockLookupAction())
            return try readObjectCodes(t) { try self.readLookupAction(t) }
        case T.objectBlockFlipAction:
            let t = A.CadBlockActionTemplate(A.BlockFlipAction())
            return try readObjectCodes(t) { try self.readBlockFlipAction(t) }
        case T.objectBlockMoveAction:
            let t = A.CadBlockActionTemplate(A.BlockMoveAction())
            return try readObjectCodes(t) { try self.readBlockMoveAction(t) }
        case T.objectBlockScaleAction:
            let t = A.CadBlockActionTemplate(A.BlockScaleAction())
            return try readObjectCodes(t) { try self.readBlockScaleAction(t) }
        case T.objectBlockStretchAction:
            let t = A.CadStretchActionBaseTemplate(A.BlockStretchAction())
            return try readObjectCodes(t) { try self.readBlockStretchAction(t) }
        case T.objectBlockPolarStretchAction:
            let t = A.CadPolarStretchActionTemplate(A.BlockPolarStretchAction())
            return try readObjectCodes(t) { try self.readBlockPolarStretchAction(t) }
        case T.objectBlockRotateAction:
            let t = A.CadBlockActionTemplate(A.BlockRotationAction())
            return try readObjectCodes(t) { try self.readBlockRotationAction(t) }
        case T.objectBlockArrayAction:
            let t = A.CadBlockActionTemplate(A.BlockArrayAction())
            return try readObjectCodes(t) { try self.readBlockArrayAction(t) }
        case T.objectField:
            let t = A.CadFieldTemplate(A.Field())
            return try readObjectCodes(t) { try self.readField(t) }
        case T.objectFieldList:
            let t = A.CadFieldListTemplate(A.FieldList())
            return try readObjectCodes(t) { try self.readFieldList(t) }
        default:
            return .none
        }
    }

    // ───────────────────────── Map plumbing ─────────────────────────

    /// `tryAssignCurrentValue(obj, map)`: the current subclass's map when the object's map has it.
    private func assignCurrent(_ object: ACad.CadObject) throws -> Bool {
        guard !currentSubclass.isEmpty, hasSubclass(object, currentSubclass) else { return false }
        return mapped { try assignSubclass(object, currentSubclass) }
    }

    /// `tryAssignCurrentValue(obj, map.SubClasses[name])`; a subclass the object does not have throws like the
    /// dictionary lookup.
    private func assign(_ object: ACad.CadObject, subclassMap name: String) throws -> Bool {
        guard hasSubclass(object, name) else {
            throw ACad.DxfException("The given key '\(name)' was not present in the dictionary.")
        }
        return mapped { try assignSubclass(object, name) }
    }

    /// `readObjectSubclassMap`.
    private func readObjectSubclassMap(_ t: ACad.CadTemplate) throws -> Bool {
        try assign(t.cadObject, subclassMap: currentSubclass.isEmpty ? t.cadObject.subclassMarker : currentSubclass)
    }

    /// One reader level: the subclass map, then the base reader.
    private func readSubclass(_ t: ACad.CadTemplate, _ name: String, then base: (ACad.CadTemplate) throws -> Bool) throws -> Bool {
        if try assign(t.cadObject, subclassMap: name) { return true }
        return try base(t)
    }

    /// The subclass markers of an object's `DxfMap`.
    private func hasSubclass(_ object: ACad.CadObject, _ name: String) -> Bool {
        typealias M = ACad.DxfSubclassMarker
        if name == object.subclassMarker { return true }
        switch name {
        case M.evalGraphExpr: return object is A.EvaluationExpression
        case M.blockElement: return object is A.BlockElement
        case M.blockParameter: return object is A.BlockParameter
        case M.block1PtParameter: return object is A.Block1PtParameter
        case M.block2PtParameter: return object is A.Block2PtParameter
        case M.blockAction: return object is A.BlockAction
        case M.blockActionBasePt: return object is A.BlockActionBasePt
        case M.blockGrip: return object is A.BlockGrip
        case M.objectContextData: return object is A.ObjectContextData
        default: return false
        }
    }

    /// The class maps (`DxfClassMap`) of these objects: code → property with ACadSharp's conversions. Integer
    /// properties only take values of their own width (`PropertyInfo.SetValue` does not widen), so e.g. the 93
    /// grip id (an Int64 property, an Int32 group) is never assigned.
    private func assignSubclass(_ object: ACad.CadObject, _ name: String) throws -> Bool {
        typealias M = ACad.DxfSubclassMarker
        let r = reader!
        let code = r.code
        let i = axis(code)
        switch (name, object) {
        case let (M.evalGraphExpr, e as A.EvaluationExpression):
            switch code {
            case 90: e.id = try r.valueAsInt
            case 98: e.value98 = try r.valueAsInt
            case 99: e.value99 = try r.valueAsInt
            default: return false
            }
        case let (M.blockElement, e as A.BlockElement):
            switch code {
            case 300: e.elementName = rawString
            case 1071: e.value1071 = try r.valueAsInt
            default: return false
            }
        case let (M.blockParameter, p as A.BlockParameter):
            switch code {
            case 280: p.showProperties = try r.valueAsBool
            case 281: p.chainActions = try r.valueAsBool
            default: return false
            }
        case let (M.block1PtParameter, p as A.Block1PtParameter):
            switch code {
            case 1010, 1020, 1030: p.location[i] = try r.valueAsDouble
            case 93: throw ACad.DxfException("Object of type 'System.Int32' cannot be converted to type 'System.Int64'.")
            default: return false
            }
        case let (M.block2PtParameter, p as A.Block2PtParameter):
            switch code {
            case 177: p.baseLocation = Int32(try r.valueAsShort)
            case 1010, 1020, 1030: p.firstPoint[i] = try r.valueAsDouble
            case 170: break
            case 1011, 1021, 1031: p.secondPoint[i] = try r.valueAsDouble
            default: return false
            }
        case let (M.blockAction, a as A.BlockAction):
            switch code {
            case 71, 70: break
            case 1010, 1020, 1030: a.labelPosition[i] = try r.valueAsDouble
            default: return false
            }
        case let (M.blockActionBasePt, a as A.BlockActionBasePt):
            switch code {
            case 1011, 1021, 1031: a.basePoint[i] = try r.valueAsDouble
            case 1012, 1022, 1032: a.value1012[i] = try r.valueAsDouble
            case 280: a.value280 = try r.valueAsBool
            default: return false
            }
        case let (M.blockGrip, g as A.BlockGrip):
            switch code {
            case 1010, 1020, 1030: g.location[i] = try r.valueAsDouble
            case 280: g.cycling = try r.valueAsBool
            case 91: g.expressionId1 = try r.valueAsInt
            case 92: g.expressionId2 = try r.valueAsInt
            case 93: g.value93 = try r.valueAsInt
            default: return false
            }
        case let (M.blockAlignmentGrip, g as A.BlockAlignmentGrip):
            switch code {
            case 140: g.alignmentX = try r.valueAsDouble
            case 141: g.alignmentY = try r.valueAsDouble
            case 142: g.alignmentZ = try r.valueAsDouble
            default: return false
            }
        case let (M.blockFlipGrip, g as A.BlockFlipGrip):
            switch code {
            case 140: g.directionX = try r.valueAsDouble
            case 141: g.directionY = try r.valueAsDouble
            case 142: g.directionZ = try r.valueAsDouble
            case 93: g.flipExpressionId = try r.valueAsInt
            default: return false
            }
        case let (M.blockLinearGrip, g as A.BlockLinearGrip):
            switch code {
            case 140: g.distanceX = try r.valueAsDouble
            case 141: g.distanceY = try r.valueAsDouble
            case 142: g.distanceZ = try r.valueAsDouble
            default: return false
            }
        case (M.blockGripExpression, is A.BlockGripLocationComponent), (M.blockLookupGrip, is A.BlockLookupGrip),
             (M.blockPolarGrip, is A.BlockPolarGrip), (M.blockRotationGrip, is A.BlockRotationGrip),
             (M.blockVisibilityGrip, is A.BlockVisibilityGrip), (M.blockXYGrip, is A.BlockXYGrip),
             (M.blockFlipAction, is A.BlockFlipAction), (M.blockRotationAction, is A.BlockRotationAction),
             (M.blockScaleAction, is A.BlockScaleAction), (M.fieldList, is A.FieldList):
            return false
        case let (M.blockAlignmentParameter, p as A.BlockAlignmentParameter):
            guard code == 280 else { return false }
            p.isPerpendicular = try r.valueAsBool
        case let (M.blockBasePointParameter, p as A.BlockBasePointParameter):
            switch code {
            case 1011, 1021, 1031: p.point1011[i] = try r.valueAsDouble
            case 1012, 1022, 1032: p.point1012[i] = try r.valueAsDouble
            default: return false
            }
        case let (M.blockFlipParameter, p as A.BlockFlipParameter):
            switch code {
            case 307: p.baseStateName = rawString
            case 306: p.description = rawString
            case 308: p.flippedStateName = rawString
            case 305: p.label = rawString
            case 1012, 1022, 1032: p.labelPosition[i] = try r.valueAsDouble
            default: return false
            }
        case let (M.blockLinearParameter, p as A.BlockLinearParameter):
            switch code {
            case 306: p.description = rawString
            case 305: p.label = rawString
            case 140: p.labelOffset = try r.valueAsDouble
            default: return false
            }
        case let (M.blockLookupParameter, p as A.BlockLookupParameter):
            switch code {
            case 94: p.actionId = try r.valueAsInt
            case 304: p.description = rawString
            case 303: p.label = rawString
            default: return false
            }
        case let (M.blockPointParameter, p as A.BlockPointParameter):
            switch code {
            case 304: p.description = rawString
            case 303: p.label = rawString
            case 1011, 1021, 1031: p.labelPosition[i] = try r.valueAsDouble
            default: return false
            }
        case let (M.blockPolarParameter, p as A.BlockPolarParameter):
            switch code {
            case 308: p.angleDescription = rawString
            case 307: p.angleName = rawString
            case 306: p.description = rawString
            case 305: p.label = rawString
            case 140: p.labelOffset = try r.valueAsDouble
            default: return false
            }
        case let (M.blockRotationParameter, p as A.BlockRotationParameter):
            switch code {
            case 306: p.description = rawString
            case 305: p.label = rawString
            case 140: p.labelOffset = try r.valueAsDouble
            case 1011, 1021, 1031: p.point[i] = try r.valueAsDouble
            default: return false
            }
        case let (M.blockXYParameter, p as A.BlockXYParameter):
            switch code {
            case 308: p.descriptionX = rawString
            case 307: p.descriptionY = rawString
            case 141: p.labelOffsetX = try r.valueAsDouble
            case 140: p.labelOffsetY = try r.valueAsDouble
            case 306: p.labelX = rawString
            case 305: p.labelY = rawString
            default: return false
            }
        case let (M.blockVisibilityParameter, p as A.BlockVisibilityParameter):
            switch code {
            case 302: p.description = rawString
            case 93, 92: break
            case 301: p.label = rawString
            case 281: p.value281 = try r.valueAsBool
            case 91: p.value91 = try r.valueAsBool
            default: return false
            }
        case let (M.blockArrayAction, a as A.BlockArrayAction):
            switch code {
            case 141: a.columnOffset = try r.valueAsDouble
            case 140: a.rowOffset = try r.valueAsDouble
            default: return false
            }
        case let (M.blockLookupAction, a as A.BlockLookupAction):
            guard code == 280 else { return false }
            a.unknownFlag = try r.valueAsBool
        case let (M.blockMoveAction, a as A.BlockMoveAction):
            switch code {
            case 141: a.angleOffset = try r.valueAsDouble
            case 140: a.distanceMultiplier = try r.valueAsDouble
            case 280: a.unknownFlag = try byteValue()
            default: return false
            }
        case let (M.blockStretchAction, a as A.BlockStretchAction):
            switch code {
            case 141: a.angleOffset = try r.valueAsDouble
            case 72: break
            case 140: a.distanceMultiplier = try r.valueAsDouble
            case 280: a.unknownFlag = try byteValue()
            default: return false
            }
        case let (M.blockPolarStretchAction, a as A.BlockPolarStretchAction):
            switch code {
            case 140: a.angleOffset = try r.valueAsDouble
            case 73: break
            case 141: a.distanceMultiplier = try r.valueAsDouble
            default: return false
            }
        case let (M.evalGraph, g as A.EvaluationGraph):
            switch code {
            case 96: g.value96 = try r.valueAsInt
            case 97: g.value97 = try r.valueAsInt
            default: return false
            }
        case let (M.dimensionAssociation, d as A.DimensionAssociation):
            switch code {
            case 90: d.associativityFlags = Int16(truncatingIfNeeded: try r.valueAsInt)
            case 330: return false
            case 70: d.isTransSpace = try r.valueAsBool
            case 71: d.rotatedDimensionType = try r.valueAsShort
            default: return false
            }
        case let (M.acDbDynamicBlockPurgePreventer, p as A.DynamicBlockPurgePreventer):
            guard code == 70 else { return false }
            p.version = try r.valueAsShort
        case let (M.blockRepresentationData, b as A.BlockRepresentationData):
            switch code {
            case 340: return false
            case 70: b.version = try r.valueAsShort
            default: return false
            }
        case let (M.geoData, g as A.GeoData):
            switch code {
            case 143: g.coordinateProjectionRadius = try r.valueAsDouble
            case 70: g.coordinatesType = try r.valueAsShort
            case 301: g.coordinateSystemDefinition = rawString
            case 10, 20, 30: g.designPoint[i] = try r.valueAsDouble
            case 294: g.enableSeaLevelCorrection = try r.valueAsBool
            case 96, 93: break
            case 302: g.geoRssTag = rawString
            case 91: g.horizontalUnits = try r.valueAsInt
            case 41: g.horizontalUnitScale = try r.valueAsDouble
            case 12, 22: g.northDirection[i] = try r.valueAsDouble
            case 307: g.observationCoverageTag = rawString
            case 305: g.observationFromTag = rawString
            case 306: g.observationToTag = rawString
            case 11, 21, 31: g.referencePoint[i] = try r.valueAsDouble
            case 95: g.scaleEstimationMethod = try r.valueAsInt
            case 142: g.seaLevelElevation = try r.valueAsDouble
            case 210, 220, 230: g.upDirection[i] = try r.valueAsDouble
            case 141: g.userSpecifiedScaleFactor = try r.valueAsDouble
            case 90: g.version = try r.valueAsInt
            case 92: g.verticalUnits = try r.valueAsInt
            case 40: g.verticalUnitScale = try r.valueAsDouble
            default: return false
            }
        case let (M.field, f as A.Field):
            switch code {
            case 97, 90, 93: break
            case 96: f.evaluationErrorCode = try r.valueAsInt
            case 300: f.evaluationErrorMessage = rawString
            case 91: f.evaluationOptionFlags = try r.valueAsInt
            case 95: f.evaluationStatusFlags = try r.valueAsInt
            case 1: f.evaluatorId = rawString
            case 2: f.fieldCode = rawString
            case 94: f.fieldStateFlags = try r.valueAsInt
            case 92: f.filingOptionFlags = try r.valueAsInt
            case 301: f.formatString = rawString
            case 7: throw ACad.DxfException("Object of type 'System.String' cannot be converted to type 'ACadSharp.CadValue'.")
            default: return false
            }
        case let (M.proxyObject, p as A.ProxyObject):
            switch code {
            case 91, 95, 90: throw ACad.DxfException("Property set method not found.")
            case 70: p.originalDataFormatDxf = try r.valueAsBool
            case 310, 311: throw ACad.DxfException("Object of type 'System.Byte[]' cannot be converted to type 'System.IO.Stream'.")
            default: return false
            }
        case let (M.objectContextData, o as A.ObjectContextData):
            switch code {
            case 70: o.version = try r.valueAsShort
            case 290: o.default = try r.valueAsBool
            default: return false
            }
        case let (M.annotScaleObjectContextData, o as A.BlockReferenceObjectContextData):
            switch code {
            case 10, 20, 30: o.insertionPoint[i] = try r.valueAsDouble
            case 50: o.rotation = try r.valueAsAngle
            case 41, 42, 43:
                let value = try r.valueAsDouble
                guard value != 0 else { throw ACad.DxfException("Scale value must be none zero.") }
                if code == 41 { o.xScale = value } else if code == 42 { o.yScale = value } else { o.zScale = value }
            default: return false
            }
        case let (M.annotScaleObjectContextData, o as A.MTextAttributeObjectContextData):
            switch code {
            case 11, 21, 31: o.alignmentPoint[i] = try r.valueAsDouble
            case 70: o.attachmentPoint = try r.valueAsShort
            case 10, 20, 30: o.insertPoint[i] = try r.valueAsDouble
            case 50: o.rotation = try r.valueAsAngle
            case 290: o.value290 = try r.valueAsBool
            default: return false
            }
        default:
            return false
        }
        return true
    }

    /// `Convert.ToByte`.
    private func byteValue() throws -> UInt8 {
        let value = try reader.valueAsInt
        guard (0...255).contains(value) else { throw ACad.DxfException("Value was either too large or too small for an unsigned byte.") }
        return UInt8(value)
    }

    // ───────────────────────── Shared pieces ─────────────────────────

    /// `readEvalConnection`.
    private func readEvalConnection(reversed: Bool = false) throws -> ACad.EvalConnection {
        var connection = ACad.EvalConnection()
        if reversed {
            connection.name = reader.valueAsString
            try reader.readNext()
            connection.id = try reader.valueAsInt
        } else {
            connection.id = try reader.valueAsInt
            try reader.readNext()
            connection.name = reader.valueAsString
        }
        return connection
    }

    /// `readEvalParameterProperty`.
    private func readEvalParameterProperty(_ property: inout ACad.EvalParameterProperty) throws {
        var count = try reader.valueAsShort
        while count > 0 {
            try reader.readNext()
            property.connections.append(try readEvalConnection())
            count -= 1
        }
    }

    /// `readParameterValueSet`.
    private func readParameterValueSet() throws -> ACad.ParameterValueSet {
        var set = ACad.ParameterValueSet()
        try reader.readNext()
        set.type = try reader.valueAsInt
        try reader.readNext()
        set.minimum = try reader.valueAsDouble
        try reader.readNext()
        set.maximum = try reader.valueAsDouble
        try reader.readNext()
        set.increment = try reader.valueAsDouble
        try reader.readNext()
        let n = try reader.valueAsInt
        for _ in 0..<max(n, 0) {
            try reader.readNext()
            set.allowedValues.append(try reader.valueAsDouble)
        }
        return set
    }

    // ───────────────────────── Expressions and parameters ─────────────────────────

    /// `readEvaluationExpression`.
    private func readEvaluationExpression(_ t: ACad.CadTemplate) throws -> Bool {
        let expression = t.cadObject as! A.EvaluationExpression
        if reader.code == 1 {
            try reader.readNext()
            let code = Int(try reader.valueAsInt)
            try reader.readNext()
            expression.evaluatedValue = ACad.DxfValuePair(code: code, value: reader.value.dxfValue)
            return true
        }
        return try assign(t.cadObject, subclassMap: ACad.DxfSubclassMarker.evalGraphExpr)
    }

    private func readBlockElement(_ t: ACad.CadTemplate) throws -> Bool {
        try readSubclass(t, ACad.DxfSubclassMarker.blockElement, then: readEvaluationExpression)
    }

    private func readBlockParameter(_ t: ACad.CadTemplate) throws -> Bool {
        try readSubclass(t, ACad.DxfSubclassMarker.blockParameter, then: readBlockElement)
    }

    private func readBlockGrip(_ t: ACad.CadTemplate) throws -> Bool {
        try readSubclass(t, ACad.DxfSubclassMarker.blockGrip, then: readBlockElement)
    }

    private func readBlock1PtParameter(_ t: ACad.CadTemplate) throws -> Bool {
        let p = t.cadObject as! A.Block1PtParameter
        switch reader.code {
        case 170: try readEvalParameterProperty(&p.displacementX)
        case 171: try readEvalParameterProperty(&p.displacementY)
        default: return try readSubclass(t, ACad.DxfSubclassMarker.block1PtParameter, then: readBlockParameter)
        }
        return true
    }

    private func readBlock2PtParameter(_ t: ACad.CadTemplate) throws -> Bool {
        let p = t.cadObject as! A.Block2PtParameter
        switch reader.code {
        case 91: p.gripIds.append(try reader.valueAsLong)
        case 171: try readEvalParameterProperty(&p.firstPointDisplacementX)
        case 172: try readEvalParameterProperty(&p.firstPointDisplacementY)
        case 173: try readEvalParameterProperty(&p.secondPointDisplacementX)
        case 174: try readEvalParameterProperty(&p.secondPointDisplacementY)
        default:
            if try assignCurrent(t.cadObject) { return true }
            return try readBlockParameter(t)
        }
        return true
    }

    private func readBlockGripLocationComponent(_ t: ACad.CadTemplate) throws -> Bool {
        if reader.code == 91 {
            (t.cadObject as! A.BlockGripLocationComponent).connection = try readEvalConnection()
            return true
        }
        return try readSubclass(t, ACad.DxfSubclassMarker.blockGripExpression, then: readEvaluationExpression)
    }

    private func readBlockLinearParameter(_ t: ACad.CadTemplate) throws -> Bool {
        if reader.code == 307 {
            (t.cadObject as! A.BlockLinearParameter).valueSet = try readParameterValueSet()
            return true
        }
        return try readSubclass(t, ACad.DxfSubclassMarker.blockLinearParameter, then: readBlock2PtParameter)
    }

    private func readBlockFlipParameter(_ t: ACad.CadTemplate) throws -> Bool {
        if reader.code == 309 {
            (t.cadObject as! A.BlockFlipParameter).updatedFlipConnection = try readEvalConnection(reversed: true)
            return true
        }
        return try readSubclass(t, ACad.DxfSubclassMarker.blockFlipParameter, then: readBlock2PtParameter)
    }

    private func readBlockPolarParameter(_ t: ACad.CadTemplate) throws -> Bool {
        let p = t.cadObject as! A.BlockPolarParameter
        switch reader.code {
        case 309: p.distanceValueSet = try readParameterValueSet()
        case 410: p.angleValueSet = try readParameterValueSet()
        default:
            if try assignCurrent(t.cadObject) { return true }
            return try readBlock2PtParameter(t)
        }
        return true
    }

    private func readBlockRotationParameter(_ t: ACad.CadTemplate) throws -> Bool {
        if reader.code == 307 {
            (t.cadObject as! A.BlockRotationParameter).valueSet = try readParameterValueSet()
            return true
        }
        if try assignCurrent(t.cadObject) { return true }
        return try readBlock2PtParameter(t)
    }

    private func readBlockXYParameter(_ t: ACad.CadTemplate) throws -> Bool {
        let p = t.cadObject as! A.BlockXYParameter
        switch reader.code {
        case 309: p.valueSetY = try readParameterValueSet()
        case 410: p.valueSetX = try readParameterValueSet()
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockXYParameter, then: readBlock2PtParameter)
        }
        return true
    }

    private func readBlockVisibilityParameter(_ t: ACad.CadBlockVisibilityParameterTemplate) throws -> Bool {
        switch reader.code {
        case 92:
            let count = try reader.valueAsInt
            for _ in 0..<max(count, 0) {
                try reader.readNext()
                t.stateTemplates.append(try readState())
            }
        case 93 where currentSubclass == ACad.DxfSubclassMarker.blockVisibilityParameter:
            let count = try reader.valueAsInt
            for _ in 0..<max(count, 0) {
                try reader.readNext()
                t.entityHandles.append(try reader.valueAsHandle)
            }
        default:
            return try readSubclass(t, ACad.DxfSubclassMarker.blockVisibilityParameter, then: readBlock1PtParameter)
        }
        return true
    }

    /// `readState`: name (303), entities (94 + 332), expressions (95 + 333) in any order.
    private func readState() throws -> ACad.CadBlockVisibilityParameterTemplate.StateTemplate {
        let template = ACad.CadBlockVisibilityParameterTemplate.StateTemplate()
        var expected = [303, 94, 95]
        while reader.code != 0 {
            if let index = expected.firstIndex(of: reader.code) { expected.remove(at: index) }
            switch reader.code {
            case 303:
                template.state.name = reader.valueAsString
            case 94:
                let count = try reader.valueAsInt
                for _ in 0..<max(count, 0) {
                    try reader.readNext()
                    template.entityHandles.insert(try reader.valueAsHandle)
                }
            case 95:
                let count = try reader.valueAsInt
                for _ in 0..<max(count, 0) {
                    try reader.readNext()
                    template.expressionHandles.insert(try reader.valueAsHandle)
                }
            default:
                return template
            }
            if expected.isEmpty { break }
            try reader.readNext()
        }
        return template
    }

    // ───────────────────────── Actions ─────────────────────────

    private func readBlockAction(_ t: ACad.CadTemplate) throws -> Bool {
        if reader.code == 71 {
            let count = try reader.valueAsInt
            for _ in 0..<max(count, 0) {
                try reader.readNext()
                (t as! ACad.CadBlockActionTemplate).entityHandles.insert(try reader.valueAsHandle)
            }
            return true
        }
        return try readSubclass(t, ACad.DxfSubclassMarker.blockAction, then: readBlockElement)
    }

    private func readBlockActionBasePt(_ t: ACad.CadTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockActionBasePt
        switch reader.code {
        case 92: action.updateBaseXConnection.id = try reader.valueAsInt
        case 93: action.updateBaseYConnection.id = try reader.valueAsInt
        case 301: action.updateBaseXConnection.name = reader.valueAsString
        case 302: action.updateBaseYConnection.name = reader.valueAsString
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockActionBasePt, then: readBlockAction)
        }
        return true
    }

    private func readBlockArrayAction(_ t: ACad.CadTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockArrayAction
        switch reader.code {
        case 92: action.baseConnection.id = try reader.valueAsInt
        case 93: action.endConnection.id = try reader.valueAsInt
        case 94: action.updatedBaseConnection.id = try reader.valueAsInt
        case 95: action.updatedEndConnection.id = try reader.valueAsInt
        case 301: action.baseConnection.name = reader.valueAsString
        case 302: action.endConnection.name = reader.valueAsString
        case 303: action.updatedBaseConnection.name = reader.valueAsString
        case 304: action.updatedEndConnection.name = reader.valueAsString
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockArrayAction, then: readBlockAction)
        }
        return true
    }

    private func readBlockFlipAction(_ t: ACad.CadTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockFlipAction
        switch reader.code {
        case 92: action.flipConnection.id = try reader.valueAsInt
        case 93: action.updatedFlipConnection.id = try reader.valueAsInt
        case 94: action.updatedBaseConnection.id = try reader.valueAsInt
        case 95: action.updatedEndConnection.id = try reader.valueAsInt
        case 301: action.flipConnection.name = reader.valueAsString
        case 302: action.updatedFlipConnection.name = reader.valueAsString
        case 303: action.updatedBaseConnection.name = reader.valueAsString
        case 304: action.updatedEndConnection.name = reader.valueAsString
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockFlipAction, then: readBlockAction)
        }
        return true
    }

    private func readBlockMoveAction(_ t: ACad.CadTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockMoveAction
        switch reader.code {
        case 92: action.xDeltaConnection = try readEvalConnection()
        case 93: action.yDeltaConnection = try readEvalConnection()
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockMoveAction, then: readBlockAction)
        }
        return true
    }

    private func readBlockRotationAction(_ t: ACad.CadTemplate) throws -> Bool {
        if reader.code == 94 {
            (t.cadObject as! A.BlockRotationAction).angleDeltaConnection = try readEvalConnection()
            return true
        }
        return try readSubclass(t, ACad.DxfSubclassMarker.blockRotationAction, then: readBlockActionBasePt)
    }

    private func readBlockScaleAction(_ t: ACad.CadTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockScaleAction
        switch reader.code {
        case 94: action.scaleConnection.id = try reader.valueAsInt
        case 95: action.xScaleConnection.id = try reader.valueAsInt
        case 96: action.yScaleConnection.id = try reader.valueAsInt
        case 303: action.scaleConnection.name = reader.valueAsString
        case 304: action.xScaleConnection.name = reader.valueAsString
        case 305: action.yScaleConnection.name = reader.valueAsString
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockScaleAction, then: readBlockActionBasePt)
        }
        return true
    }

    /// Stretch bindings: count, then per entity its handle, a point count and the point indexes.
    private func readStretchBindings(_ t: ACad.CadStretchActionBaseTemplate) throws {
        let n = try reader.valueAsInt
        for _ in 0..<max(n, 0) {
            try reader.readNext()
            let handle = try reader.valueAsHandle
            try reader.readNext()
            let count = try reader.valueAsInt
            var indexes: [Int32] = []
            for _ in 0..<max(count, 0) {
                try reader.readNext()
                indexes.append(try reader.valueAsInt)
            }
            try t.addBinding(handle, indexes)
        }
    }

    private func readStretchNodes(_ action: A.StretchActionBase) throws {
        let n = try reader.valueAsInt
        for _ in 0..<max(n, 0) {
            try reader.readNext()
            let nodeId = try reader.valueAsInt
            try reader.readNext()
            let count = try reader.valueAsInt
            var indexes: [Int32] = []
            for _ in 0..<max(count, 0) {
                try reader.readNext()
                indexes.append(try reader.valueAsInt)
            }
            action.stretchNodes.append(ACad.StretchNode(nodeId: nodeId, pointIndexes: indexes))
        }
    }

    private func readBoundary(_ action: A.StretchActionBase) throws {
        let n = try reader.valueAsInt
        for _ in 0..<max(n, 0) {
            try reader.readNext()
            let x = try reader.valueAsDouble
            try reader.readNext()
            action.boundary.append(ACad.XY(x, try reader.valueAsDouble))
        }
    }

    private func readBlockStretchAction(_ t: ACad.CadStretchActionBaseTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockStretchAction
        switch reader.code {
        case 72: try readBoundary(action)
        case 73: try readStretchBindings(t)
        case 75: try readStretchNodes(action)
        case 92: action.endXDeltaConnection = try readEvalConnection()
        case 93: action.endYDeltaConnection = try readEvalConnection()
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockStretchAction, then: readBlockAction)
        }
        return true
    }

    private func readBlockPolarStretchAction(_ t: ACad.CadPolarStretchActionTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockPolarStretchAction
        switch reader.code {
        case 72:
            let n = try reader.valueAsInt
            for _ in 0..<max(n, 0) {
                try reader.readNext()
                t.selectionHandles.append(try reader.valueAsHandle)
            }
        case 73: try readBoundary(action)
        case 74: try readStretchBindings(t)
        case 77: break
        case 78: try readStretchNodes(action)
        case 92: action.baseXDeltaConnection = try readEvalConnection()
        case 93: action.baseYDeltaConnection = try readEvalConnection()
        case 94: action.baseConnection = try readEvalConnection()
        case 95: action.endConnection = try readEvalConnection()
        case 96: action.updatedBaseConnection = try readEvalConnection()
        case 97: action.updatedEndConnection = try readEvalConnection()
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockPolarStretchAction, then: readBlockAction)
        }
        return true
    }

    private func readLookupAction(_ t: ACad.CadBlockLookupActionTemplate) throws -> Bool {
        let action = t.cadObject as! A.BlockLookupAction
        switch reader.code {
        case 92: t.numberOfRows = try reader.valueAsInt
        case 93: t.numberOfColumns = try reader.valueAsInt
        case 301: break
        case 302: t.rowValues.append(reader.valueAsString)
        case 303:
            let column = A.BlockLookupAction.ColumnData()
            try reader.expectedCode(94)
            column.nodeId = try reader.valueAsInt
            try reader.expectedCode(95)
            column.valueType = try reader.valueAsInt
            try reader.expectedCode(96)
            column.type = try reader.valueAsInt
            try reader.expectedCode(282)
            column.isLookupProperty = try reader.valueAsShort == 1
            try reader.expectedCode(305)
            column.unmatchedName = reader.valueAsString
            try reader.expectedCode(281)
            column.isReadOnly = try reader.valueAsShort == 0
            try reader.expectedCode(304)
            column.connectionName = reader.valueAsString
            action.columns.append(column)
        default: return try readSubclass(t, ACad.DxfSubclassMarker.blockLookupAction, then: readBlockAction)
        }
        return true
    }

    // ───────────────────────── Graph ─────────────────────────

    private func readEvaluationGraph(_ t: ACad.CadEvaluationGraphTemplate) throws -> Bool {
        let graph = t.cadObject as! A.EvaluationGraph
        switch reader.code {
        case 91:
            while reader.code == 91 {
                let node = graph.createNode()
                node.index = try reader.valueAsInt
                try reader.expectedCode(93)
                node.flags = try reader.valueAsInt
                try reader.expectedCode(95)
                node.id = try reader.valueAsInt
                try reader.expectedCode(360)
                let handle = try reader.valueAsHandle
                try reader.expectedCode(92)
                node.data1 = try reader.valueAsInt
                try reader.expectedCode(92)
                node.data2 = try reader.valueAsInt
                try reader.expectedCode(92)
                node.data3 = try reader.valueAsInt
                try reader.expectedCode(92)
                node.data4 = try reader.valueAsInt
                try reader.readNext()
                t.nodeTemplates.append((node, handle))
            }
            lockPointer = true
        case 92:
            while reader.code == 92 {
                var edge = A.EvaluationGraph.Edge()
                edge.index = try reader.valueAsInt
                try reader.expectedCode(93)
                edge.flags = try reader.valueAsInt
                try reader.expectedCode(94)
                edge.trackedCount = try reader.valueAsInt
                try reader.expectedCode(91)
                edge.fromNodeIndex = try reader.valueAsInt
                try reader.expectedCode(91)
                edge.toNodeIndex = try reader.valueAsInt
                try reader.expectedCode(92)
                edge.data1 = try reader.valueAsInt
                try reader.expectedCode(92)
                edge.data2 = try reader.valueAsInt
                try reader.expectedCode(92)
                edge.data3 = try reader.valueAsInt
                try reader.expectedCode(92)
                edge.data4 = try reader.valueAsInt
                try reader.expectedCode(92)
                edge.data5 = try reader.valueAsInt
                try reader.readNext()
                graph.edges.append(edge)
            }
            lockPointer = true
        default:
            return try assign(t.cadObject, subclassMap: ACad.DxfSubclassMarker.evalGraph)
        }
        return true
    }

    // ───────────────────────── Dimension associativity ─────────────────────────

    private func readDimensionAssociation(_ t: ACad.CadDimensionAssociationTemplate) throws -> Bool {
        let association = t.cadObject as! A.DimensionAssociation
        typealias F = A.DimensionAssociation.Flags
        switch reader.code {
        case 1 where reader.valueAsString == A.DimensionAssociation.osnapPointRefClassName:
            let flags = association.associativityFlags
            func next(_ flag: Int16, _ current: A.DimensionAssociation.OsnapPointRef?,
                      _ set: (A.DimensionAssociation.OsnapPointRef) -> Void) throws -> Bool {
                guard flags & flag != 0, current == nil else { return false }
                let pointRef = A.DimensionAssociation.OsnapPointRef()
                set(pointRef)
                t.pointRefTemplates.append(try readOsnapPointRef(pointRef))
                lockPointer = true
                return true
            }
            if try next(F.firstPointReference, association.firstPointRef, { association.firstPointRef = $0 }) { return true }
            if try next(F.secondPointReference, association.secondPointRef, { association.secondPointRef = $0 }) { return true }
            if try next(F.thirdPointReference, association.thirdPointRef, { association.thirdPointRef = $0 }) { return true }
            if try next(F.fourthPointReference, association.fourthPointRef, { association.fourthPointRef = $0 }) { return true }
            return true
        case 330 where t.ownerHandle != nil:
            t.dimensionHandle = try reader.valueAsHandle
            return true
        default:
            return try assign(t.cadObject, subclassMap: t.cadObject.subclassMarker)
        }
    }

    /// `readOsnapPointRef`: the reference's codes up to the first other one.
    private func readOsnapPointRef(_ pointRef: A.DimensionAssociation.OsnapPointRef)
        throws -> ACad.CadDimensionAssociationTemplate.OsnapPointRefTemplate {
        let template = ACad.CadDimensionAssociationTemplate.OsnapPointRefTemplate(pointRef)
        try reader.readNext()
        while true {
            switch reader.code {
            case 10: pointRef.osnapPoint.x = try reader.valueAsDouble
            case 20: pointRef.osnapPoint.y = try reader.valueAsDouble
            case 30: pointRef.osnapPoint.z = try reader.valueAsDouble
            case 40: pointRef.geometryParameter = try reader.valueAsDouble
            case 72: pointRef.objectOsnapType = try reader.valueAsShort
            case 73: pointRef.subentType = try reader.valueAsShort
            case 74: pointRef.intersectionSubType = try reader.valueAsShort
            case 75: pointRef.hasLastPointRef = try reader.valueAsBool
            case 91: pointRef.gsMarker = try reader.valueAsInt
            case 92: pointRef.intersectionGsMarker = try reader.valueAsInt
            case 331: template.objectHandle = try reader.valueAsHandle
            case 302, 332: break
            default: return template
            }
            try reader.readNext()
        }
    }

    // ───────────────────────── Other objects ─────────────────────────

    private func readAnnotScaleObjectContextData(_ t: ACad.CadAnnotScaleObjectContextDataTemplate) throws -> Bool {
        if reader.code == 340 {
            t.scaleHandle = try reader.valueAsHandle
            return true
        }
        return try assign(t.cadObject, subclassMap: currentSubclass.isEmpty ? t.cadObject.subclassMarker : currentSubclass)
    }

    private func readGeoData(_ t: ACad.CadTemplate) throws -> Bool {
        let geo = t.cadObject as! A.GeoData
        let r2009 = geo.version == A.GeoData.GeoDataVersion.r2009
        switch reader.code {
        case 40 where r2009: geo.referencePoint.y = try reader.valueAsDouble
        case 41 where r2009: geo.referencePoint.x = try reader.valueAsDouble
        case 42 where r2009: geo.referencePoint.z = try reader.valueAsDouble
        case 46 where r2009: geo.horizontalUnitScale = try reader.valueAsDouble
        case 52 where r2009:
            let angle = Double.pi / 2 - (try reader.valueAsAngle)
            geo.northDirection = ACad.XY(Foundation.cos(angle), Foundation.sin(angle))
        case 93:
            let n = try reader.valueAsInt
            for _ in 0..<max(n, 0) {
                try reader.readNext()
                let sx = try reader.valueAsDouble
                try reader.readNext()
                let sy = try reader.valueAsDouble
                try reader.readNext()
                let dx = try reader.valueAsDouble
                try reader.readNext()
                let dy = try reader.valueAsDouble
                geo.points.append(.init(source: ACad.XY(sx, sy), destination: ACad.XY(dx, dy)))
            }
        case 96:
            let n = try reader.valueAsInt
            for _ in 0..<max(n, 0) {
                try reader.readNext()
                let i1 = try reader.valueAsInt
                try reader.readNext()
                let i2 = try reader.valueAsInt
                try reader.readNext()
                geo.faces.append(.init(index1: i1, index2: i2, index3: try reader.valueAsInt))
            }
        case 303:
            geo.coordinateSystemDefinition += reader.valueAsString
        case 3, 4, 14, 24, 15, 25, 43, 44, 45, 94, 293, 16, 26, 17, 27, 54, 140, 304, 292:
            break
        default:
            return try assign(t.cadObject, subclassMap: t.cadObject.subclassMarker)
        }
        return true
    }

    private func readProxyObject(_ t: ACad.CadProxyObjectTemplate) throws -> Bool {
        let proxy = t.cadObject as! A.ProxyObject
        switch reader.code {
        case 90, 94, 97, 71, 161, 162:
            break
        case 95:
            let format = try reader.valueAsInt
            proxy.version = ACad.Version(rawValue: Int16(truncatingIfNeeded: format & 0xFFFF)) ?? .unknown
            proxy.maintenanceVersion = Int32(Int16(truncatingIfNeeded: format >> 16))
        case 91:
            if let dxfClass = builder.document.classes.byClassNumber(try reader.valueAsShort) { proxy.dxfClass = dxfClass }
        case 310:
            proxy.binaryData = (proxy.binaryData ?? Data()) + (reader.valueAsBinaryChunk ?? Data())
        case 311:
            proxy.data = (proxy.data ?? Data()) + (reader.valueAsBinaryChunk ?? Data())
        case 330, 340, 350, 360:
            t.entries.append(try reader.valueAsHandle)
        default:
            return try assign(t.cadObject, subclassMap: ACad.DxfSubclassMarker.proxyObject)
        }
        return true
    }

    private func readField(_ t: ACad.CadFieldTemplate) throws -> Bool {
        let field = t.cadObject as! A.Field
        switch reader.code {
        case 3: field.fieldCode = (field.fieldCode ?? "") + reader.valueAsString
        case 98: break
        case 6:
            let key = reader.valueAsString
            let template = try readCadValue(A.CadValue())
            guard field.values.add(key, template.value) else {
                throw ACad.DxfException("An item with the same key has already been added. Key: \(key)")
            }
            t.cadValueTemplates.append(template)
        case 7:
            let template = try readCadValue(A.CadValue())
            field.value = template.value
            t.cadValueTemplates.append(template)
        case 331: t.cadObjectsHandles.append(try reader.valueAsHandle)
        case 360: t.childrenHandles.append(try reader.valueAsHandle)
        default: return try assign(t.cadObject, subclassMap: ACad.DxfSubclassMarker.field)
        }
        return true
    }

    private func readFieldList(_ t: ACad.CadFieldListTemplate) throws -> Bool {
        switch reader.code {
        case 100 where reader.valueAsString == ACad.DxfSubclassMarker.idSet:
            currentSubclass = reader.valueAsString
        case 90 where currentSubclass == ACad.DxfSubclassMarker.idSet:
            break
        case 330 where currentSubclass == ACad.DxfSubclassMarker.idSet:
            t.ownedObjectsHandlers.insert(try reader.valueAsHandle)
        default:
            return try assign(t.cadObject, subclassMap: ACad.DxfSubclassMarker.fieldList)
        }
        return true
    }

    /// `readCadValue`: the groups up to the 304 end marker.
    func readCadValue(_ value: A.CadValue) throws -> ACad.CadValueTemplate {
        try reader.readNext()
        let template = ACad.CadValueTemplate(value)
        func vector() throws -> ACad.XYZ {
            switch value.value {
            case let .point2D(v)?: return ACad.XYZ(v.x, v.y, 0)
            case let .point3D(v)?: return v
            default: throw ACad.DxfException("Object reference not set to an instance of an object.")
            }
        }
        while reader.code != 304 {
            switch reader.code {
            case 1:
                try value.setValue(.string(reader.valueAsString))
            case 2:
                var text = ""
                if case let .string(s)? = value.value { text = s }
                try value.setValue(.string(text + reader.valueAsString))
            case 11:
                try value.setValue(.point3D(ACad.XYZ(try reader.valueAsDouble, 0, 0)))
            case 21:
                var v = try vector()
                v.y = try reader.valueAsDouble
                // The vector keeps its dimension: an XY stays 2D.
                if case .point2D? = value.value { try value.setValue(.point2D(v.xy)) } else { try value.setValue(.point3D(v)) }
            case 31:
                var v = try vector()
                v.z = try reader.valueAsDouble
                try value.setValue(.point3D(v))
            case 90:
                value.valueType = try reader.valueAsInt
            case 91:
                try value.setValue(.int(try reader.valueAsInt))
            case 93:
                value.flags = try reader.valueAsInt
            case 140:
                try value.setValue(.double(try reader.valueAsDouble))
            case 330:
                template.valueHandle = try reader.valueAsHandle
            default:
                let assigned = mapped {
                    switch reader.code {
                    case 300: value.format = rawString
                    case 302: value.formattedValue = rawString
                    case 94: value.units = try reader.valueAsInt
                    default: return false
                    }
                    return true
                }
                if !assigned {
                    builder.notify("Unhandled dxf code \(reader.code) value \(reader.valueAsString) at readCadValue method.")
                }
            }
            try reader.readNext()
        }
        return template
    }
}
