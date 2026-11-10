// Dynamic block objects of the CAD document model (ACadSharp Objects.Evaluations): the evaluation graph stored in
// a block's ACAD_ENHANCEDBLOCK entry with its parameters, grips and actions. They are kept so that DWG ↔ DXF
// keeps dynamic blocks; nothing here is drawn.

import Foundation

extension ACad {
    /// `EvalConnection`: a named connection to another node of the graph.
    struct EvalConnection {
        static let displacementX = "DisplacementX", displacementY = "DisplacementY", scale = "Scale"
        static let xScale = "XScale", yScale = "YScale"

        var id: Int32 = 0
        var name: String?
    }

    /// `EvalParameterProperty`.
    struct EvalParameterProperty {
        var connections: [EvalConnection] = []
    }

    /// `ParameterValueSetType`.
    enum ParameterValueSetType {
        static let none: Int32 = 1, unknown: Int32 = 2, increment: Int32 = 4, list: Int32 = 8
    }

    /// `ParameterValueSet`.
    struct ParameterValueSet {
        var allowedValues: [Double] = []
        var increment = 0.0
        var maximum = 0.0
        var minimum = 0.0
        var type: Int32 = 0
    }

    /// `StretchEntityBind`.
    struct StretchEntityBind {
        var entity: Entity?
        var pointIndexes: [Int32] = []
    }

    /// `StretchNode`.
    struct StretchNode {
        var nodeId: Int32
        var pointIndexes: [Int32]
    }

    /// `DxfValuePair`: an evaluated value with its group code.
    struct DxfValuePair {
        var code: Int
        var value: DxfValue
    }

    // ───────────────────────── Expressions ─────────────────────────

    /// `EvaluationExpression`.
    class EvaluationExpression: NonGraphicalObject {
        var evaluatedValue: DxfValuePair?
        var id: Int32 = 0
        var value98: Int32 = 0
        var value99: Int32 = 0
        /// Not stored in DXF.
        var unknown: Int32 = -1

        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.evalGraphExpr }
    }

    /// `BlockElement`.
    class BlockElement: EvaluationExpression {
        var elementName: String?
        var value1071: Int32 = 0
        override var subclassMarker: String { DxfSubclassMarker.blockElement }
    }

    /// `BlockParameter`.
    class BlockParameter: BlockElement {
        var showProperties = true
        var chainActions = false
        override var subclassMarker: String { DxfSubclassMarker.blockParameter }
    }

    /// `Block1PtParameter`.
    class Block1PtParameter: BlockParameter {
        var displacementX = EvalParameterProperty()
        var displacementY = EvalParameterProperty()
        var gripId: Int64 = 0
        var location = XYZ.zero
        override var subclassMarker: String { DxfSubclassMarker.block1PtParameter }
    }

    /// `Block2PtParameter`.
    class Block2PtParameter: BlockParameter {
        /// `LinearParameterBaseLocation` (177): 0 start point, 1 middle point.
        var baseLocation: Int32 = 0
        var firstPoint = XYZ.zero
        var firstPointDisplacementX = EvalParameterProperty()
        var firstPointDisplacementY = EvalParameterProperty()
        var gripIds: [Int64] = []
        var secondPoint = XYZ.zero
        var secondPointDisplacementX = EvalParameterProperty()
        var secondPointDisplacementY = EvalParameterProperty()
        override var subclassMarker: String { DxfSubclassMarker.block2PtParameter }
    }

    /// `BlockAction`.
    class BlockAction: BlockElement {
        var entities: [Entity] = []
        var labelPosition = XYZ.zero
        var parametersIds: [Int32] = []
        override var subclassMarker: String { DxfSubclassMarker.blockAction }
    }

    /// `BlockActionBasePt`.
    class BlockActionBasePt: BlockAction {
        var basePoint = XYZ.zero
        var updateBaseXConnection = EvalConnection()
        var updateBaseYConnection = EvalConnection()
        var value1012 = XYZ.zero
        var value280 = false
        override var subclassMarker: String { DxfSubclassMarker.blockActionBasePt }
    }

    /// `BlockGrip`.
    class BlockGrip: BlockElement {
        var location = XYZ.zero
        var cycling = true
        var expressionId1: Int32 = 0
        var expressionId2: Int32 = 0
        var value93: Int32 = 0
        override var subclassMarker: String { DxfSubclassMarker.blockGrip }
    }

    /// `StretchActionBase` (an empty DXF subclass: its values belong to the derived action).
    class StretchActionBase: BlockAction {
        var angleOffset = 0.0
        var boundary: [XY] = []
        var distanceMultiplier = 0.0
        var stretchBindings: [StretchEntityBind] = []
        var stretchNodes: [StretchNode] = []
    }

    /// The class definition every dynamic block object writes (`GetDxfClass`).
    fileprivate static func evaluationClass(_ cppName: String, _ dxfName: String, maintenance: Int16 = 55) -> DxfClass {
        DxfClass(cppName, dxfName, dwgVersion: Version.ac1018.rawValue, itemClassId: 499, maintenance: maintenance,
                 proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
    }

    // ───────────────────────── Grips ─────────────────────────

    final class BlockAlignmentGrip: BlockGrip, DxfClassDefined {
        var alignmentX = 0.0, alignmentY = 0.0, alignmentZ = 0.0
        override var objectName: String { DxfFileToken.objectBlockAlignmentGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockAlignmentGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockAlignmentGrip, DxfFileToken.objectBlockAlignmentGrip) }
    }

    final class BlockFlipGrip: BlockGrip, DxfClassDefined {
        var directionX = 0.0, directionY = 0.0, directionZ = 0.0
        var flipExpressionId: Int32 = 0
        override var objectName: String { DxfFileToken.objectBlockFlipGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockFlipGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockFlipGrip, DxfFileToken.objectBlockFlipGrip) }
    }

    final class BlockLinearGrip: BlockGrip, DxfClassDefined {
        var distanceX = 0.0, distanceY = 0.0, distanceZ = 0.0
        override var objectName: String { DxfFileToken.objectBlockLinearGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockLinearGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockLinearGrip, DxfFileToken.objectBlockLinearGrip) }
    }

    final class BlockLookupGrip: BlockGrip, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectBlockLookupGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockLookupGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockLookupGrip, DxfFileToken.objectBlockLookupGrip) }
    }

    final class BlockPolarGrip: BlockGrip, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectBlockPolarGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockPolarGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockPolarGrip, DxfFileToken.objectBlockPolarGrip) }
    }

    final class BlockRotationGrip: BlockGrip, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectBlockRotationGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockRotationGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockRotationGrip, DxfFileToken.objectBlockRotationGrip) }
    }

    final class BlockVisibilityGrip: BlockGrip, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectBlockVisibilityGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockVisibilityGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockVisibilityGrip, DxfFileToken.objectBlockVisibilityGrip) }
    }

    final class BlockXYGrip: BlockGrip, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectBlockXYGrip }
        override var subclassMarker: String { DxfSubclassMarker.blockXYGrip }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockXYGrip, DxfFileToken.objectBlockXYGrip) }
    }

    final class BlockGripLocationComponent: EvaluationExpression, DxfClassDefined {
        var connection = EvalConnection()
        override var objectName: String { DxfFileToken.objectBlockGripLocationComponent }
        override var subclassMarker: String { DxfSubclassMarker.blockGripExpression }
        func dxfClass() -> DxfClass {
            evaluationClass(DxfSubclassMarker.blockGripExpression, DxfFileToken.objectBlockGripLocationComponent, maintenance: 20)
        }
    }

    // ───────────────────────── Parameters ─────────────────────────

    final class BlockAlignmentParameter: Block2PtParameter, DxfClassDefined {
        var isPerpendicular = false
        override var objectName: String { DxfFileToken.objectBlockAlignmentParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockAlignmentParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockAlignmentParameter, DxfFileToken.objectBlockAlignmentParameter) }
    }

    final class BlockBasePointParameter: Block1PtParameter, DxfClassDefined {
        var point1011 = XYZ.zero
        var point1012 = XYZ.zero
        override var objectName: String { DxfFileToken.objectBlockBasePointParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockBasePointParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockBasePointParameter, DxfFileToken.objectBlockBasePointParameter) }
    }

    final class BlockFlipParameter: Block2PtParameter, DxfClassDefined {
        var baseStateName: String?
        var description: String?
        var flippedStateName: String?
        var label: String?
        var labelPosition = XYZ.zero
        var updatedFlipConnection: EvalConnection?
        override var objectName: String { DxfFileToken.objectBlockFlipParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockFlipParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockFlipParameter, DxfFileToken.objectBlockFlipParameter) }
    }

    final class BlockLinearParameter: Block2PtParameter, DxfClassDefined {
        var description: String?
        var label: String?
        var labelOffset = 0.0
        var valueSet: ParameterValueSet? = ParameterValueSet()
        override var objectName: String { DxfFileToken.objectBlockLinearParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockLinearParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockLinearParameter, DxfFileToken.objectBlockLinearParameter) }
    }

    final class BlockLookupParameter: Block1PtParameter, DxfClassDefined {
        var actionId: Int32 = 0
        var description: String? = ""
        var label: String? = ""
        override var objectName: String { DxfFileToken.objectBlockLookupParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockLookupParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockLookupParameter, DxfFileToken.objectBlockLookupParameter) }
    }

    final class BlockPointParameter: Block1PtParameter, DxfClassDefined {
        var description: String?
        var label: String?
        var labelPosition = XYZ.zero
        override var objectName: String { DxfFileToken.objectBlockPointParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockPointParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockPointParameter, DxfFileToken.objectBlockPointParameter) }
    }

    final class BlockPolarParameter: Block2PtParameter, DxfClassDefined {
        var angleDescription: String?
        var angleName: String?
        var angleValueSet: ParameterValueSet?
        var description: String?
        var distanceValueSet: ParameterValueSet?
        var label: String?
        var labelOffset = 0.0
        override var objectName: String { DxfFileToken.objectBlockPolarParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockPolarParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockPolarParameter, DxfFileToken.objectBlockPolarParameter) }
    }

    final class BlockRotationParameter: Block2PtParameter, DxfClassDefined {
        var description: String?
        var label: String?
        var labelOffset = 0.0
        var point = XYZ.zero
        var valueSet: ParameterValueSet?
        override var objectName: String { DxfFileToken.objectBlockRotationParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockRotationParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockRotationParameter, DxfFileToken.objectBlockRotationParameter) }
    }

    final class BlockXYParameter: Block2PtParameter, DxfClassDefined {
        var descriptionX: String?
        var descriptionY: String?
        var labelOffsetX = 0.0
        var labelOffsetY = 0.0
        var labelX: String?
        var labelY: String?
        var valueSetX: ParameterValueSet?
        var valueSetY: ParameterValueSet?
        override var objectName: String { DxfFileToken.objectBlockXYParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockXYParameter }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockXYParameter, DxfFileToken.objectBlockXYParameter) }
    }

    final class BlockVisibilityParameter: Block1PtParameter, DxfClassDefined {
        final class State {
            var name: String?
            var entities: [Entity] = []
            var expressions: [EvaluationExpression] = []
        }

        var description: String?
        var entities: [Entity] = []
        var label: String?
        /// Keyed by name without case (`InvariantCultureIgnoreCase`).
        private(set) var states = NameMap<State>()
        var value281 = false
        var value91 = false

        override var objectName: String { DxfFileToken.objectBlockVisibilityParameter }
        override var subclassMarker: String { DxfSubclassMarker.blockVisibilityParameter }

        /// `AddState`; false where ACadSharp throws (a state name used twice).
        @discardableResult
        func addState(_ state: State) -> Bool { states.add(state.name ?? "", state) }

        func dxfClass() -> DxfClass {
            evaluationClass(DxfSubclassMarker.blockVisibilityParameter, DxfFileToken.objectBlockVisibilityParameter)
        }
    }

    // ───────────────────────── Actions ─────────────────────────

    final class BlockArrayAction: BlockAction, DxfClassDefined {
        var baseConnection = EvalConnection()
        var columnOffset = 0.0
        var endConnection = EvalConnection()
        var rowOffset = 0.0
        var updatedBaseConnection = EvalConnection()
        var updatedEndConnection = EvalConnection()
        override var objectName: String { DxfFileToken.objectBlockArrayAction }
        override var subclassMarker: String { DxfSubclassMarker.blockArrayAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockArrayAction, DxfFileToken.objectBlockArrayAction) }
    }

    final class BlockFlipAction: BlockAction, DxfClassDefined {
        var flipConnection = EvalConnection()
        var updatedBaseConnection = EvalConnection()
        var updatedEndConnection = EvalConnection()
        var updatedFlipConnection = EvalConnection()
        override var objectName: String { DxfFileToken.objectBlockFlipAction }
        override var subclassMarker: String { DxfSubclassMarker.blockFlipAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockFlipAction, DxfFileToken.objectBlockFlipAction) }
    }

    final class BlockLookupAction: BlockAction, DxfClassDefined {
        final class ColumnData {
            var connectionName: String?
            var isLookupProperty = false
            var isReadOnly = false
            var nodeId: Int32 = 0
            var rows: [String] = []
            var type: Int32 = 0
            var unmatchedName: String?
            var valueType: Int32 = 0
        }

        var columns: [ColumnData] = []
        var unknownFlag = false
        override var objectName: String { DxfFileToken.objectBlockLookupAction }
        override var subclassMarker: String { DxfSubclassMarker.blockLookupAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockLookupAction, DxfFileToken.objectBlockLookupAction) }
    }

    final class BlockMoveAction: BlockAction, DxfClassDefined {
        var angleOffset = 0.0
        var distanceMultiplier = 0.0
        var unknownFlag: UInt8 = 0
        var xDeltaConnection: EvalConnection?
        var yDeltaConnection: EvalConnection?
        override var objectName: String { DxfFileToken.objectBlockMoveAction }
        override var subclassMarker: String { DxfSubclassMarker.blockMoveAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockMoveAction, DxfFileToken.objectBlockMoveAction) }
    }

    final class BlockRotationAction: BlockActionBasePt, DxfClassDefined {
        var angleDeltaConnection: EvalConnection?
        override var objectName: String { DxfFileToken.objectBlockRotateAction }
        override var subclassMarker: String { DxfSubclassMarker.blockRotationAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockRotationAction, DxfFileToken.objectBlockRotateAction) }
    }

    final class BlockScaleAction: BlockActionBasePt, DxfClassDefined {
        var scaleConnection = EvalConnection()
        var scaleType: UInt8 = 0
        var xScaleConnection = EvalConnection()
        var yScaleConnection = EvalConnection()
        override var objectName: String { DxfFileToken.objectBlockScaleAction }
        override var subclassMarker: String { DxfSubclassMarker.blockScaleAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockScaleAction, DxfFileToken.objectBlockScaleAction) }
    }

    /// `BlockStretchAction`: angle offset 141, distance multiplier 140, boundary count 72.
    final class BlockStretchAction: StretchActionBase, DxfClassDefined {
        var endXDeltaConnection: EvalConnection?
        var endYDeltaConnection: EvalConnection?
        var unknownFlag: UInt8 = 0
        override var objectName: String { DxfFileToken.objectBlockStretchAction }
        override var subclassMarker: String { DxfSubclassMarker.blockStretchAction }
        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.blockStretchAction, DxfFileToken.objectBlockStretchAction) }
    }

    /// `BlockPolarStretchAction`: angle offset 140, distance multiplier 141, boundary count 73.
    final class BlockPolarStretchAction: StretchActionBase, DxfClassDefined {
        var baseConnection: EvalConnection?
        var baseXDeltaConnection: EvalConnection?
        var baseYDeltaConnection: EvalConnection?
        var endConnection: EvalConnection?
        var rotateBindings: [Entity] = []
        var updatedBaseConnection: EvalConnection?
        var updatedEndConnection: EvalConnection?
        override var objectName: String { DxfFileToken.objectBlockPolarStretchAction }
        override var subclassMarker: String { DxfSubclassMarker.blockPolarStretchAction }
        func dxfClass() -> DxfClass {
            evaluationClass(DxfSubclassMarker.blockPolarStretchAction, DxfFileToken.objectBlockPolarStretchAction)
        }
    }

    // ───────────────────────── Graph ─────────────────────────

    /// `EvaluationGraph`: the nodes (expressions) and edges of a dynamic block.
    final class EvaluationGraph: NonGraphicalObject, DxfClassDefined {
        static let dictionaryEntryName = "ACAD_ENHANCEDBLOCK"

        /// `EvaluationGraph.NodeFlags`.
        enum NodeFlags {
            static let none: Int32 = 0, visited: Int32 = 1, outsideRefed: Int32 = 2, selected: Int32 = 4, inList: Int32 = 8
        }

        final class Node {
            var data1: Int32 = 0, data2: Int32 = 0, data3: Int32 = 0, data4: Int32 = 0
            var flags: Int32 = 0
            var id: Int32 = 0
            var index: Int32 = 0
            private unowned let graph: EvaluationGraph
            private(set) var expression: EvaluationExpression?

            init(_ graph: EvaluationGraph) { self.graph = graph }

            /// The expression joins the graph's document and is owned by the graph.
            func setExpression(_ value: EvaluationExpression) {
                graph.document?.addCadObject(value)
                if let expression { graph.document?.removeCadObject(expression) }
                expression = value
                value.owner = graph
            }
        }

        struct Edge {
            var data1: Int32 = 0, data2: Int32 = 0, data3: Int32 = 0, data4: Int32 = 0, data5: Int32 = 0
            var flags: Int32 = 0
            var fromNodeIndex: Int32 = 0
            var index: Int32 = 0
            var toNodeIndex: Int32 = 0
            var trackedCount: Int32 = 0
        }

        var edges: [Edge] = []
        private(set) var nodes: [Node] = []
        var value96: Int32 = 0
        var value97: Int32 = 0

        override var objectName: String { DxfFileToken.objectEvalGraph }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.evalGraph }

        func createNode() -> Node {
            let node = Node(self)
            nodes.append(node)
            return node
        }

        func dxfClass() -> DxfClass { evaluationClass(DxfSubclassMarker.evalGraph, DxfFileToken.objectEvalGraph) }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            for node in nodes { if let expression = node.expression { document.addCadObject(expression) } }
        }
    }
}
