// Entities of the CAD document model (ACadSharp Entities): property names and defaults follow ACadSharp 3.8.

import Foundation

extension ACad {
    // ───────────────────────── Simple geometry ─────────────────────────

    final class Line: Entity, Orientable {
        var startPoint = XYZ.zero
        var endPoint = XYZ.zero
        var normal = XYZ.axisZ
        var thickness = 0.0

        override init() { super.init() }
        init(_ start: XYZ, _ end: XYZ) {
            startPoint = start
            endPoint = end
            super.init()
        }

        override var objectName: String { DxfFileToken.entityLine }
        override var objectType: ObjectType { .line }
        override var subclassMarker: String { DxfSubclassMarker.line }
    }

    class Circle: Entity, Orientable {
        var center = XYZ.zero
        var normal = XYZ.axisZ
        var radius = 1.0
        var thickness = 0.0

        override var objectName: String { DxfFileToken.entityCircle }
        override var objectType: ObjectType { .circle }
        override var subclassMarker: String { DxfSubclassMarker.circle }
    }

    final class Arc: Circle {
        var startAngle = 0.0
        var endAngle = Double.pi

        override var objectName: String { DxfFileToken.entityArc }
        override var objectType: ObjectType { .arc }
        override var subclassMarker: String { DxfSubclassMarker.arc }
    }

    final class Ellipse: Entity, Orientable {
        var center = XYZ.zero
        var majorAxisEndPoint = XYZ.axisX
        var normal = XYZ.axisZ
        var radiusRatio = 1.0
        var startParameter = 0.0
        var endParameter = MathHelper.twoPI
        var thickness = 0.0

        override var objectName: String { DxfFileToken.entityEllipse }
        override var objectType: ObjectType { .ellipse }
        override var subclassMarker: String { DxfSubclassMarker.ellipse }
    }

    final class Point: Entity, Orientable {
        var location = XYZ.zero
        var normal = XYZ.axisZ
        var rotation = 0.0
        var thickness = 0.0

        override init() { super.init() }
        init(_ location: XYZ) {
            self.location = location
            super.init()
        }

        override var objectName: String { DxfFileToken.entityPoint }
        override var objectType: ObjectType { .point }
        override var subclassMarker: String { DxfSubclassMarker.point }
    }

    final class Ray: Entity {
        var startPoint = XYZ.zero
        var direction = XYZ.zero

        override var objectName: String { DxfFileToken.entityRay }
        override var objectType: ObjectType { .ray }
        override var subclassMarker: String { DxfSubclassMarker.ray }
    }

    final class XLine: Entity {
        var firstPoint = XYZ.zero
        var direction = XYZ.zero

        override var objectName: String { DxfFileToken.entityXline }
        override var objectType: ObjectType { .xline }
        override var subclassMarker: String { DxfSubclassMarker.xLine }
    }

    /// SOLID and TRACE.
    final class Solid: Entity, Orientable {
        var firstCorner = XYZ.zero
        var secondCorner = XYZ.zero
        var thirdCorner = XYZ.zero
        var fourthCorner = XYZ.zero
        var normal = XYZ.axisZ
        var thickness = 0.0

        override var objectName: String { DxfFileToken.entitySolid }
        override var objectType: ObjectType { .solid }
        override var subclassMarker: String { DxfSubclassMarker.solid }
    }

    /// `InvisibleEdgeFlags`.
    enum InvisibleEdgeFlags {
        static let first: Int16 = 1, second: Int16 = 2, third: Int16 = 4, fourth: Int16 = 8
    }

    final class Face3D: Entity {
        var firstCorner = XYZ.zero
        var secondCorner = XYZ.zero
        var thirdCorner = XYZ.zero
        var fourthCorner = XYZ.zero
        /// `InvisibleEdgeFlags` (70).
        var flags: Int16 = 0

        override var objectName: String { DxfFileToken.entity3DFace }
        override var objectType: ObjectType { .face3D }
        override var subclassMarker: String { DxfSubclassMarker.face3d }
    }

    final class Shape: Entity, Orientable {
        var insertionPoint = XYZ.zero
        var normal = XYZ.axisZ
        var obliqueAngle = 0.0
        var relativeXScale = 1.0
        var rotation = 0.0
        var size = 1.0
        var thickness = 0.0
        var shapeStyle: TextStyle?
        var shapeIndex: UInt16 = 0
        /// DXF shape name (2), resolved against the shape file when known.
        var shapeName: String?

        override var objectName: String { DxfFileToken.entityShape }
        override var objectType: ObjectType { .shape }
        override var subclassMarker: String { DxfSubclassMarker.shape }
    }

    final class Seqend: Entity {
        override var objectName: String { DxfFileToken.entitySeqend }
        override var objectType: ObjectType { .seqend }
    }

    // ───────────────────────── Text ─────────────────────────

    /// `TextHorizontalAlignment`.
    enum TextHorizontalAlignment {
        static let left: Int16 = 0, center: Int16 = 1, right: Int16 = 2, aligned: Int16 = 3, middle: Int16 = 4, fit: Int16 = 5
    }

    /// `TextVerticalAlignmentType`.
    enum TextVerticalAlignment {
        static let baseline: Int16 = 0, bottom: Int16 = 1, middle: Int16 = 2, top: Int16 = 3
    }

    /// TEXT (and the base of ATTRIB / ATTDEF).
    class TextEntity: Entity, Orientable {
        var alignmentPoint = XYZ.zero
        var height = 1.0
        var horizontalAlignment: Int16 = TextHorizontalAlignment.left
        var insertPoint = XYZ.zero
        /// `TextMirrorFlag` (71).
        var mirror: Int16 = 0
        var normal = XYZ.axisZ
        var obliqueAngle = 0.0
        var rotation = 0.0
        private var _style: TextStyle?
        /// Standard unless set.
        var style: TextStyle {
            get {
                if let style = _style { return style }
                let style = TextStyle.makeDefault()
                _style = style
                return style
            }
            set { _style = newValue }
        }
        var styleIfSet: TextStyle? { _style }
        var thickness = 0.0
        var value = ""
        var verticalAlignment: Int16 = TextVerticalAlignment.baseline
        var widthFactor = 1.0

        override init() { super.init() }
        init(_ value: String) {
            self.value = value
            super.init()
        }

        override var objectName: String { DxfFileToken.entityText }
        override var objectType: ObjectType { .text }
        override var subclassMarker: String { DxfSubclassMarker.text }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _style = document.textStyles.resolve(style)
        }
    }

    /// `AttributeFlags`.
    enum AttributeFlags {
        static let hidden: Int16 = 1, constant: Int16 = 2, verify: Int16 = 4, preset: Int16 = 8
    }

    /// `AttributeType`.
    enum AttributeType {
        static let singleLine: UInt8 = 1, multiLine: UInt8 = 2, constantMultiLine: UInt8 = 4
    }

    class AttributeBase: TextEntity {
        var attributeType: UInt8 = AttributeType.singleLine
        /// `AttributeFlags` (70).
        var flags: Int16 = 0
        var isLocked = false
        var mtext: MText?
        var tag = ""
        var version: UInt8 = 0

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            if let mtext { document.addCadObject(mtext) }
        }
    }

    final class AttributeEntity: AttributeBase {
        override var objectName: String { DxfFileToken.entityAttribute }
        override var objectType: ObjectType { .attrib }
        override var subclassMarker: String { DxfSubclassMarker.attribute }
    }

    final class AttributeDefinition: AttributeBase {
        var prompt = ""

        override var objectName: String { DxfFileToken.entityAttributeDefinition }
        override var objectType: ObjectType { .attdef }
        override var subclassMarker: String { DxfSubclassMarker.attributeDefinition }
    }

    /// `AttachmentPointType`.
    enum AttachmentPoint {
        static let topLeft: Int16 = 1, topCenter: Int16 = 2, topRight: Int16 = 3
        static let middleLeft: Int16 = 4, middleCenter: Int16 = 5, middleRight: Int16 = 6
        static let bottomLeft: Int16 = 7, bottomCenter: Int16 = 8, bottomRight: Int16 = 9
    }

    final class MText: Entity, Orientable {
        /// `MText.TextColumnData`.
        final class TextColumnData {
            /// `ColumnType` (71).
            var columnType: Int16 = 0
            var columnCount: Int32 = 0
            var flowReversed = false
            var autoHeight = false
            var width = 0.0
            var gutter = 0.0
            var heights: [Double] = []
        }

        var alignmentPoint = XYZ.axisX
        var attachmentPoint: Int16 = AttachmentPoint.topLeft
        var backgroundColor = Color.byBlock
        /// `BackgroundFillFlags` (90).
        var backgroundFillFlags: Int32 = 0
        var backgroundScale = 1.5
        var backgroundTransparency = Transparency.byLayer
        var columnData = TextColumnData()
        /// `DrawingDirectionType` (72).
        var drawingDirection: Int16 = 1
        var height = 1.0
        var horizontalWidth = 0.9
        var insertPoint = XYZ.zero
        var isAnnotative = false
        var lineSpacing = 1.0
        /// `LineSpacingStyleType` (73).
        var lineSpacingStyle: Int16 = 0
        var normal = XYZ.axisZ
        var rectangleHeight = 0.0
        var rectangleWidth = 0.0
        private var _style: TextStyle?
        var style: TextStyle {
            get {
                if let style = _style { return style }
                let style = TextStyle.makeDefault()
                _style = style
                return style
            }
            set { _style = newValue }
        }
        var styleIfSet: TextStyle? { _style }
        var value = ""
        var verticalHeight = 0.2

        override init() { super.init() }
        init(_ value: String) {
            self.value = value
            super.init()
        }

        override var objectName: String { DxfFileToken.entityMText }
        override var objectType: ObjectType { .mtext }
        override var subclassMarker: String { DxfSubclassMarker.mText }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _style = document.textStyles.resolve(style)
        }
    }

    // ───────────────────────── Blocks ─────────────────────────

    class Insert: Entity, Orientable {
        private(set) var attributes: SeqendCollection<AttributeEntity>!
        var block: BlockRecord?
        var columnCount: UInt16 = 1
        var columnSpacing = 0.0
        var insertPoint = XYZ.zero
        var normal = XYZ.axisZ
        var rotation = 0.0
        var rowCount: UInt16 = 1
        var rowSpacing = 0.0
        var xScale = 1.0
        var yScale = 1.0
        var zScale = 1.0

        override init() {
            super.init()
            attributes = SeqendCollection<AttributeEntity>(owner: self)
        }

        var isMultiple: Bool { rowCount > 1 || columnCount > 1 }
        var hasAttributes: Bool { !attributes.isEmpty }

        override var objectName: String { DxfFileToken.entityInsert }
        override var objectType: ObjectType { isMultiple ? .minsert : .insert }
        override var subclassMarker: String { isMultiple ? DxfSubclassMarker.mInsert : DxfSubclassMarker.insert }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            attributes.registerAll(in: document)
            if let current = block, !(document.blockRecords[current.name] === current) {
                block = document.blockRecords.tryAdd(current)
            }
        }
    }

    /// ACAD_TABLE: drawn through its anonymous block like an insert. The table data itself (rows, columns, cells)
    /// is not modelled; see `rawCellCount` for what was read.
    final class TableEntity: Insert {
        var horizontalDirection = XYZ.axisX
        var version: Int16 = 0
        var valueFlag: Int32 = 0
        var tableStyle: NonGraphicalObject?

        override var objectName: String { DxfFileToken.entityTable }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.tableEntity }
    }

    // ───────────────────────── Polylines ─────────────────────────

    /// `VertexFlags`.
    enum VertexFlags {
        static let curveFittingExtraVertex: Int16 = 1
        static let curveFitTangent: Int16 = 2
        static let splineVertexFromSplineFitting: Int16 = 8
        static let splineFrameControlPoint: Int16 = 16
        static let polylineVertex3D: Int16 = 32
        static let polygonMesh3D: Int16 = 64
        static let polyFaceMeshVertex: Int16 = 128
    }

    /// VERTEX (base of the 2D, 3D, mesh and polyface vertices).
    class Vertex: Entity {
        var bulge = 0.0
        var curveTangent = 0.0
        var endWidth = 0.0
        /// `VertexFlags` (70).
        var flags: Int16 = 0
        var id: Int32 = 0
        var location = XYZ.zero
        var startWidth = 0.0

        override var objectName: String { DxfFileToken.entityVertex }
        override var subclassMarker: String { DxfSubclassMarker.vertex }
    }

    final class Vertex2D: Vertex {
        override var objectType: ObjectType { .vertex2D }
        override var subclassMarker: String { DxfSubclassMarker.polylineVertex }
    }

    final class Vertex3D: Vertex {
        override var objectType: ObjectType { .vertex3D }
        override var subclassMarker: String { DxfSubclassMarker.polyline3dVertex }
    }

    final class VertexFaceMesh: Vertex {
        override var objectType: ObjectType { .vertexPface }
        override var subclassMarker: String { DxfSubclassMarker.polyfaceMeshVertex }
    }

    final class PolygonMeshVertex: Vertex {
        override var objectType: ObjectType { .vertexMesh }
        override var subclassMarker: String { DxfSubclassMarker.polygonMeshVertex }
    }

    final class VertexFaceRecord: Vertex {
        var index1: Int16 = 0
        var index2: Int16 = 0
        var index3: Int16 = 0
        var index4: Int16 = 0

        override var objectType: ObjectType { .vertexPfaceFace }
        override var subclassMarker: String { DxfSubclassMarker.polyfaceMeshFace }
    }

    /// `PolylineFlags`.
    enum PolylineFlags {
        static let closed: Int16 = 1
        static let curveFit: Int16 = 2
        static let splineFit: Int16 = 4
        static let polyline3D: Int16 = 8
        static let polygonMesh: Int16 = 16
        static let closedPolygonMeshInN: Int16 = 32
        static let polyfaceMesh: Int16 = 64
        static let continuousLinetypePattern: Int16 = 128
    }

    /// POLYLINE (`Polyline<T>`): 2D, 3D, polygon mesh or polyface mesh with its vertices.
    class Polyline: Entity, Orientable {
        var elevation = 0.0
        var endWidth = 0.0
        /// `PolylineFlags` (70).
        var flags: Int16 = 0
        var normal = XYZ.axisZ
        var startWidth = 0.0
        var thickness = 0.0
        /// `SmoothSurfaceType` (75).
        var smoothSurface: Int16 = 0
        private(set) var vertices: SeqendCollection<Vertex>!

        override init() {
            super.init()
            vertices = SeqendCollection<Vertex>(owner: self)
        }

        var isClosed: Bool { flags & PolylineFlags.closed != 0 }

        override var objectName: String { DxfFileToken.entityPolyline }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            vertices.registerAll(in: document)
        }
    }

    final class Polyline2D: Polyline {
        override var objectType: ObjectType { .polyline2D }
        override var subclassMarker: String { DxfSubclassMarker.polyline }
    }

    final class Polyline3D: Polyline {
        override var objectType: ObjectType { .polyline3D }
        override var subclassMarker: String { DxfSubclassMarker.polyline3d }
    }

    final class PolygonMesh: Polyline {
        var mVertexCount: Int16 = 0
        var nVertexCount: Int16 = 0
        var mSmoothSurfaceDensity: Int16 = 0
        var nSmoothSurfaceDensity: Int16 = 0

        override var objectType: ObjectType { .polylineMesh }
        override var subclassMarker: String { DxfSubclassMarker.polygonMesh }
    }

    final class PolyfaceMesh: Polyline {
        private(set) var faces: CadObjectCollection<VertexFaceRecord>!

        override init() {
            super.init()
            faces = CadObjectCollection<VertexFaceRecord>(owner: self)
        }

        override var objectType: ObjectType { .polylinePface }
        override var subclassMarker: String { DxfSubclassMarker.polyfaceMesh }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            faces.registerAll(in: document)
        }
    }

    final class LwPolyline: Entity, Orientable {
        /// `LwPolyline.Vertex`.
        struct Vertex {
            var bulge = 0.0
            var curveTangent = 0.0
            var endWidth = 0.0
            var flags: Int16 = 0
            var id: Int32 = 0
            var location = XY.zero
            var startWidth = 0.0

            init(_ x: Double = 0, _ y: Double = 0) { location = XY(x, y) }
        }

        var constantWidth = 0.0
        var elevation = 0.0
        /// `LwPolylineFlags` (70): 1 closed, 128 plinegen.
        var flags: Int16 = 0
        var normal = XYZ.axisZ
        var thickness = 0.0
        var vertices: [Vertex] = []

        var isClosed: Bool {
            get { flags & 1 != 0 }
            set { flags = newValue ? flags | 1 : flags & ~1 }
        }

        override var objectName: String { DxfFileToken.entityLwPolyline }
        override var objectType: ObjectType { .lwpolyline }
        override var subclassMarker: String { DxfSubclassMarker.lwPolyline }
    }

    // ───────────────────────── Curves and surfaces ─────────────────────────

    /// `SplineFlags`.
    enum SplineFlags {
        static let closed: Int16 = 1, periodic: Int16 = 2, rational: Int16 = 4, planar: Int16 = 8, linear: Int16 = 16
    }

    final class Spline: Entity, Orientable {
        var controlPoints: [XYZ] = []
        var controlPointTolerance = 0.0000001
        var degree: Int32 = 3
        var endTangent = XYZ.zero
        var fitPoints: [XYZ] = []
        var fitTolerance = 0.0000000001
        /// `SplineFlags` (70).
        var flags: Int16 = 0
        /// `SplineFlags1` (DWG only).
        var flags1: Int32 = 0
        /// `KnotParametrization` (DWG only).
        var knotParametrization: Int32 = 0
        var knots: [Double] = []
        var knotTolerance = 0.0000001
        var normal = XYZ.axisZ
        var startTangent = XYZ.zero
        var weights: [Double] = []

        override var objectName: String { DxfFileToken.entitySpline }
        override var objectType: ObjectType { .spline }
        override var subclassMarker: String { DxfSubclassMarker.spline }
    }

    /// `Mesh` (subdivision mesh).
    final class Mesh: Entity {
        struct Edge {
            var start: Int32
            var end: Int32
            var crease: Double?
        }

        var blendCrease = false
        var edges: [Edge] = []
        var faces: [[Int32]] = []
        var subdivisionLevel: Int32 = 0
        var version: Int16 = 2
        var vertices: [XYZ] = []

        override var objectName: String { DxfFileToken.entityMesh }
        override var subclassMarker: String { DxfSubclassMarker.mesh }
    }

    /// 3DSOLID, REGION and BODY (`ModelerGeometry`): the ACIS data is kept as read.
    class ModelerGeometry: Entity {
        var modelerFormatVersion: Int16 = 1
        /// SAT text lines (DXF 1 / 3 codes or decoded DWG data).
        var proprietaryData = ""
        /// SAB binary data (R2007+ DWG).
        var acisData: Data?

        override var subclassMarker: String { DxfSubclassMarker.modelerGeometry }
    }

    final class Solid3D: ModelerGeometry {
        var history: CadObject?
        override var objectName: String { DxfFileToken.entity3DSolid }
        override var objectType: ObjectType { .solid3D }
        override var subclassMarker: String { DxfSubclassMarker.solid3D }
    }

    final class Region: ModelerGeometry {
        override var objectName: String { DxfFileToken.entityRegion }
        override var objectType: ObjectType { .region }
    }

    final class CadBody: ModelerGeometry {
        override var objectName: String { DxfFileToken.entityBody }
        override var objectType: ObjectType { .body }
    }

    // ───────────────────────── Hatch ─────────────────────────

    /// `HatchPattern` with its line families (stored already scaled and rotated, like AutoCAD).
    final class HatchPattern {
        final class Line {
            var angle = 0.0
            var basePoint = XY.zero
            var offset = XY.zero
            var dashLengths: [Double] = []
        }

        var name: String
        var description: String?
        var lines: [Line] = []

        init(_ name: String) { self.name = name }

        static func makeSolid() -> HatchPattern { HatchPattern("SOLID") }
    }

    /// `HatchGradientPattern`.
    final class HatchGradientPattern {
        struct GradientColor {
            var value = 0.0
            var color = Color.byLayer
        }

        var enabled = false
        var reserved: Int32 = 0
        var angle = 0.0
        var shift = 0.0
        var isSingleColorGradient = false
        var colorTint = 0.0
        var colors: [GradientColor] = []
        var name = ""
    }

    /// `BoundaryPathFlags`.
    enum BoundaryPathFlags {
        static let external: Int32 = 1, polyline: Int32 = 2, derived: Int32 = 4, textbox: Int32 = 8, outermost: Int32 = 16
    }

    final class Hatch: Entity, Orientable {
        /// `Hatch.BoundaryPath`.
        final class BoundaryPath {
            /// The edge types of a boundary path (`Hatch.BoundaryPath.Edge` subclasses).
            enum Edge {
                case line(start: XY, end: XY)
                case arc(center: XY, radius: Double, startAngle: Double, endAngle: Double, counterClockWise: Bool)
                case ellipse(center: XY, majorAxisEndPoint: XY, radiusRatio: Double, startAngle: Double, endAngle: Double,
                             counterClockWise: Bool)
                case spline(Spline)
                /// Vertices carry the bulge in Z.
                case polyline(vertices: [XYZ], isClosed: Bool, hasBulge: Bool)

                var typeCode: Int32 {
                    switch self {
                    case .polyline: return 0
                    case .line: return 1
                    case .arc: return 2
                    case .ellipse: return 3
                    case .spline: return 4
                    }
                }
            }

            /// `Hatch.BoundaryPath.Spline`; rational control points keep their weight in Z.
            struct Spline {
                var controlPoints: [XYZ] = []
                var degree: Int32 = 0
                var endTangent = XY.zero
                var fitPoints: [XY] = []
                var isPeriodic = false
                var isRational = false
                var knots: [Double] = []
                var startTangent = XY.zero
            }

            var edges: [Edge] = []
            var entities: [Entity] = []
            /// Boundary object handles (97 / 330) resolved after reading.
            var entityHandles: [UInt64] = []
            var flags: Int32 = BoundaryPathFlags.external

            var isPolyline: Bool { edges.count == 1 && { if case .polyline = edges[0] { return true }; return false }() }
        }

        var elevation = 0.0
        var gradientColor = HatchGradientPattern()
        var isAssociative = false
        var isDouble = false
        var isSolid = false
        var normal = XYZ.axisZ
        var paths: [BoundaryPath] = []
        var pattern = HatchPattern.makeSolid()
        var patternAngle = 0.0
        var patternScale = 0.0
        /// `HatchPatternType` (76).
        var patternType: Int16 = 0
        var pixelSize = 0.0
        var seedPoints: [XY] = []
        /// `HatchStyleType` (75).
        var style: Int16 = 0

        override var objectName: String { DxfFileToken.entityHatch }
        override var objectType: ObjectType { .hatch }
        override var subclassMarker: String { DxfSubclassMarker.hatch }
    }

    // ───────────────────────── Dimensions ─────────────────────────

    /// `DimensionType` flags (70).
    enum DimensionType {
        static let linear: Int16 = 0, aligned: Int16 = 1, angular: Int16 = 2, diameter: Int16 = 3, radius: Int16 = 4
        static let angular3Point: Int16 = 5, ordinate: Int16 = 6
        static let blockReference: Int16 = 32, ordinateTypeX: Int16 = 64, textUserDefinedLocation: Int16 = 128
    }

    class Dimension: Entity, Orientable {
        var attachmentPoint: Int16 = 0
        var block: BlockRecord?
        var definitionPoint = XYZ.zero
        /// `DimensionType` (70), including the BlockReference flag.
        var flags: Int16
        var flipArrow1 = false
        var flipArrow2 = false
        var horizontalDirection = 0.0
        var insertionPoint = XYZ.zero
        var lineSpacingFactor = 0.0
        var lineSpacingStyle: Int16 = 0
        var normal = XYZ.axisZ
        private var _style: DimensionStyle?
        var style: DimensionStyle {
            get {
                if let style = _style { return style }
                let style = DimensionStyle.makeDefault()
                _style = style
                return style
            }
            set { _style = newValue }
        }
        var styleIfSet: DimensionStyle? { _style }
        var text: String?
        var textMiddlePoint = XYZ.zero
        var textRotation = 0.0
        var version: UInt8 = 0

        init(type: Int16) {
            flags = type | DimensionType.blockReference
            super.init()
        }

        /// The dimension's measured value (`Measurement`); throws for degenerate definition points.
        func measurement() throws -> Double { 0 }

        var isAngular: Bool {
            flags & DimensionType.angular3Point == DimensionType.angular3Point || flags & DimensionType.angular == DimensionType.angular
        }

        var isTextUserDefinedLocation: Bool {
            get { flags & DimensionType.textUserDefinedLocation != 0 }
            set {
                flags = newValue ? flags | DimensionType.textUserDefinedLocation : flags & ~DimensionType.textUserDefinedLocation
            }
        }

        override var objectName: String { DxfFileToken.entityDimension }
        override var subclassMarker: String { DxfSubclassMarker.dimension }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _style = document.dimensionStyles.resolve(style)
            if let block {
                self.block = document.blockRecords.resolve(block)
            }
        }
    }

    class DimensionAligned: Dimension {
        var extLineRotation = 0.0
        var firstPoint = XYZ.zero
        var secondPoint = XYZ.zero

        init() { super.init(type: DimensionType.aligned) }
        override init(type: Int16) { super.init(type: type) }

        override func measurement() throws -> Double { XYZ.distance(firstPoint, secondPoint) }

        var offset: Double {
            get {
                let dir = secondPoint - firstPoint
                let v = XYZ.cross(normal, dir).normalized()
                return XYZ.dot(definitionPoint - secondPoint, v)
            }
            set {
                let dir = secondPoint - firstPoint
                let v = XYZ.cross(normal, dir).normalized()
                definitionPoint = secondPoint + v * newValue
            }
        }

        override var objectType: ObjectType { .dimensionAligned }
        override var subclassMarker: String { DxfSubclassMarker.alignedDimension }
    }

    final class DimensionLinear: DimensionAligned {
        var rotation = 0.0

        override init() { super.init(type: DimensionType.linear) }

        override func measurement() throws -> Double {
            let angle = rotation
            let refPoint = XYZ(cos(angle), sin(angle), 0)
            return abs(XYZ.dot(secondPoint - firstPoint, refPoint))
        }

        override var objectType: ObjectType { .dimensionLinear }
        override var subclassMarker: String { DxfSubclassMarker.linearDimension }
    }

    final class DimensionRadius: Dimension {
        var angleVertex = XYZ.zero
        var leaderLength = 0.0

        init() { super.init(type: DimensionType.radius) }

        override func measurement() throws -> Double { XYZ.distance(definitionPoint, angleVertex) }

        override var objectType: ObjectType { .dimensionRadius }
        override var subclassMarker: String { DxfSubclassMarker.radialDimension }
    }

    final class DimensionDiameter: Dimension {
        var angleVertex = XYZ.zero
        var leaderLength = 0.0

        init() { super.init(type: DimensionType.diameter) }

        override func measurement() throws -> Double { XYZ.distance(definitionPoint, angleVertex) }

        var center: XYZ { (definitionPoint + angleVertex) / 2 }

        override var objectType: ObjectType { .dimensionDiameter }
        override var subclassMarker: String { DxfSubclassMarker.diametricDimension }
    }

    final class DimensionAngular2Line: Dimension {
        var angleVertex = XYZ.zero
        var dimensionArc = XYZ.zero
        var firstPoint = XYZ.zero
        var secondPoint = XYZ.zero

        init() { super.init(type: DimensionType.angular) }

        override func measurement() throws -> Double {
            let v1 = secondPoint - firstPoint
            let v2 = definitionPoint - angleVertex
            let cross = XYZ.cross(v1, v2)
            if cross.isEqual(.zero) { throw ConversionError("The angular dimension's lines are parallel.") }
            return angleBetween(v1, v2)
        }

        override var objectType: ObjectType { .dimensionAng2Ln }
        override var subclassMarker: String { DxfSubclassMarker.angular2LineDimension }
    }

    final class DimensionAngular3Pt: Dimension {
        var angleVertex = XYZ.zero
        var firstPoint = XYZ.zero
        var secondPoint = XYZ.zero

        init() { super.init(type: DimensionType.angular3Point) }

        override func measurement() throws -> Double {
            let v1 = firstPoint - angleVertex
            let v2 = secondPoint - angleVertex
            if v1.isEqual(v2) { throw ConversionError("The angular dimension's points coincide.") }
            return angleBetween(v1, v2)
        }

        override var objectType: ObjectType { .dimensionAng3Pt }
        override var subclassMarker: String { DxfSubclassMarker.angular3PointDimension }
    }

    final class DimensionArc: Dimension {
        var center = XYZ.zero
        var endAngle = 0.0
        var firstPoint = XYZ.zero
        var hasLeader = false
        var isPartial = false
        var leaderPoint1 = XYZ.zero
        var leaderPoint2 = XYZ.zero
        var secondPoint = XYZ.zero
        var startAngle = 0.0

        init() { super.init(type: DimensionType.angular3Point) }

        override func measurement() throws -> Double {
            let radius = XYZ.distance(center, firstPoint)
            return radius * abs(endAngle - startAngle)
        }

        override var objectName: String { DxfFileToken.entityArcDimension }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.arcDimension }
    }

    final class DimensionOrdinate: Dimension {
        var featureLocation = XYZ.zero
        var leaderEndpoint = XYZ.zero

        init() { super.init(type: DimensionType.ordinate) }

        var isOrdinateTypeX: Bool {
            get { flags & DimensionType.ordinateTypeX != 0 }
            set { flags = newValue ? flags | DimensionType.ordinateTypeX : flags & ~DimensionType.ordinateTypeX }
        }

        override func measurement() throws -> Double {
            isOrdinateTypeX ? abs(featureLocation.x - definitionPoint.x) : abs(featureLocation.y - definitionPoint.y)
        }

        override var objectType: ObjectType { .dimensionOrdinate }
        override var subclassMarker: String { DxfSubclassMarker.ordinateDimension }
    }

    /// The angle between two vectors (`XYZ.AngleBetweenVectors`).
    fileprivate static func angleBetween(_ a: XYZ, _ b: XYZ) -> Double {
        let den = a.length * b.length
        guard den > 0 else { return 0 }
        return acos(max(-1, min(1, XYZ.dot(a, b) / den)))
    }

    // ───────────────────────── Leaders ─────────────────────────

    final class Leader: Entity, Orientable {
        var annotationOffset = XYZ.zero
        var arrowHeadEnabled = false
        var associatedAnnotation: Entity?
        var blockOffset = XYZ.zero
        /// `LeaderCreationType` (73).
        var creationType: Int16 = 3
        var hookLineDirection: Int16 = 0
        var horizontalDirection = XYZ.axisX
        var normal = XYZ.axisZ
        /// `LeaderPathType` (72): 0 straight, 1 spline.
        var pathType: Int16 = 0
        private var _style: DimensionStyle?
        /// Standard unless set.
        var style: DimensionStyle {
            get {
                if let style = _style { return style }
                let style = DimensionStyle.makeDefault()
                _style = style
                return style
            }
            set { _style = newValue }
        }
        var textHeight = 0.0
        var textWidth = 0.0
        var vertices: [XYZ] = []
        /// Undocumented DWG values kept for writing.
        var byBlockColor = Color.byBlock

        override var objectName: String { DxfFileToken.entityLeader }
        override var objectType: ObjectType { .leader }
        override var subclassMarker: String { DxfSubclassMarker.leader }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _style = document.dimensionStyles.resolve(style)
        }
    }

    final class MultiLeader: Entity {
        /// `MultiLeader.BlockAttribute`.
        struct BlockAttribute {
            var attributeDefinition: AttributeDefinition?
            var attributeHandle: UInt64 = 0
            var index: Int16 = 0
            var width = 0.0
            var text = ""
        }

        /// `MultiLeader.ArrowheadAssociation`.
        struct ArrowheadAssociation {
            var arrowheadIndex: Int32 = 0
            var arrowhead: BlockRecord?
        }

        var arrowhead: BlockRecord?
        var arrowheadSize = 0.0
        var arrowheads: [ArrowheadAssociation] = []
        var blockAttributes: [BlockAttribute] = []
        var blockContent: BlockRecord?
        var blockContentColor = Color.byBlock
        var blockContentConnection: Int16 = 0
        var blockContentRotation = 0.0
        var blockContentScale = XYZ.zero
        var contentType: Int16 = 0
        var contextData = MultiLeaderObjectContextData()
        var enableAnnotationScale = false
        var enableDogleg = false
        var enableLanding = false
        var extendedToText = false
        var landingDistance = 0.0
        private var _leaderLineType: LineType?
        var leaderLineType: LineType {
            get {
                if let lineType = _leaderLineType { return lineType }
                let lineType = LineType.makeByLayer()
                _leaderLineType = lineType
                return lineType
            }
            set { _leaderLineType = newValue }
        }
        var leaderLineWeight: LineWeight = .w0
        var lineColor = Color.byBlock
        var pathType: Int16 = 0
        /// `MultiLeaderPropertyOverrideFlags` (90).
        var propertyOverrideFlags: Int32 = 0
        var scaleFactor = 0.0
        private var _style: MultiLeaderStyle?
        var style: MultiLeaderStyle {
            get {
                if let style = _style { return style }
                let style = MultiLeaderStyle(name: MultiLeaderStyle.defaultName)
                _style = style
                return style
            }
            set { _style = newValue }
        }
        var textAligninIPE: Int16 = 0
        var textAlignment: Int16 = 0
        var textAngle: Int16 = 0
        var textAttachmentDirection: Int16 = 0
        var textAttachmentPoint: Int16 = 0
        var textBottomAttachment: Int16 = 0
        var textColor = Color.byBlock
        var textDirectionNegative = false
        var textFrame = false
        var textLeftAttachment: Int16 = 0
        var textRightAttachment: Int16 = 0
        private var _textStyle: TextStyle?
        var textStyle: TextStyle {
            get {
                if let style = _textStyle { return style }
                let style = TextStyle.makeDefault()
                _textStyle = style
                return style
            }
            set { _textStyle = newValue }
        }
        var textTopAttachment: Int16 = 0
        /// Class version (270, R2010+).
        var version: Int16 = 2

        override var objectName: String { DxfFileToken.entityMultiLeader }
        override var subclassMarker: String { DxfSubclassMarker.multiLeader }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _textStyle = document.textStyles.resolve(textStyle)
            _leaderLineType = document.lineTypes.resolve(leaderLineType)
            if let collection = document.mleaderStyles { _style = collection.resolve(style) }
        }
    }

    // ───────────────────────── Multilines ─────────────────────────

    final class MLine: Entity, Orientable {
        final class Vertex {
            final class Segment {
                var parameters: [Double] = []
                var areaFillParameters: [Double] = []
            }

            var position = XYZ.zero
            var direction = XYZ.zero
            var miter = XYZ.zero
            var segments: [Segment] = []
        }

        /// `MLineFlags` (71).
        var flags: Int16 = 0
        /// `MLineJustification` (70).
        var justification: Int16 = 0
        var normal = XYZ.axisZ
        var scaleFactor = 1.0
        var startPoint = XYZ.zero
        var style: MLineStyle?
        var vertices: [Vertex] = []

        override var objectName: String { DxfFileToken.entityMLine }
        override var objectType: ObjectType { .mline }
        override var subclassMarker: String { DxfSubclassMarker.mLine }
    }

    /// `MLineFlags`.
    enum MLineFlags {
        static let hasVertices: Int16 = 1, closed: Int16 = 2, noStartCaps: Int16 = 4, noEndCaps: Int16 = 8
    }

    // ───────────────────────── Images, underlays, OLE, tolerance, proxies ─────────────────────────

    /// IMAGE and WIPEOUT (`CadWipeoutBase`).
    class CadWipeoutBase: Entity {
        var brightness: UInt8 = 50
        var classVersion: Int32 = 0
        var clipBoundaryVertices: [XY] = []
        /// `ClipMode` (290): 0 outside, 1 inside.
        var clipMode: UInt8 = 0
        var clippingState = false
        /// `ClipType` (71): 1 rectangular, 2 polygonal.
        var clipType: Int16 = 1
        var contrast: UInt8 = 50
        var definition: ImageDefinition?
        var definitionReactor: ImageDefinitionReactor?
        var fade: UInt8 = 0
        /// `ImageDisplayFlags` (70).
        var flags: Int16 = 0
        var insertPoint = XYZ.zero
        var size = XY.zero
        var uVector = XYZ.axisX
        var vVector = XYZ.axisY
    }

    final class RasterImage: CadWipeoutBase {
        override var objectName: String { DxfFileToken.entityImage }
        override var subclassMarker: String { DxfSubclassMarker.rasterImage }
    }

    final class Wipeout: CadWipeoutBase {
        override var objectName: String { DxfFileToken.entityWipeout }
        override var subclassMarker: String { DxfSubclassMarker.wipeout }
    }

    /// PDFUNDERLAY (`UnderlayEntity<PdfUnderlayDefinition>`).
    final class PdfUnderlay: Entity, Orientable {
        var clipBoundaryVertices: [XY] = []
        var contrast: UInt8 = 100
        var definition: PdfUnderlayDefinition?
        var fade: UInt8 = 0
        /// `UnderlayDisplayFlags` (280).
        var flags: UInt8 = 0x0B
        var insertPoint = XYZ.zero
        var normal = XYZ.axisZ
        var rotation = 0.0
        var xScale = 1.0
        var yScale = 1.0
        var zScale = 1.0

        override var objectName: String { DxfFileToken.entityPdfUnderlay }
        override var subclassMarker: String { DxfSubclassMarker.underlay }
    }

    final class Ole2Frame: Entity {
        var binaryData = Data()
        var isPaperSpace = false
        var lowerRightCorner = XYZ.zero
        /// `OleObjectType` (71).
        var oleObjectType: Int16 = 2
        var sourceApplication: String?
        var upperLeftCorner = XYZ(1, 1, 0)
        var version: Int16 = 2

        override var objectName: String { DxfFileToken.entityOle2Frame }
        override var objectType: ObjectType { .ole2frame }
        override var subclassMarker: String { DxfSubclassMarker.ole2Frame }
    }

    final class Tolerance: Entity, Orientable {
        var direction = XYZ.zero
        var insertionPoint = XYZ.zero
        var normal = XYZ.axisZ
        private var _style: DimensionStyle?
        /// Standard unless set.
        var style: DimensionStyle {
            get {
                if let style = _style { return style }
                let style = DimensionStyle.makeDefault()
                _style = style
                return style
            }
            set { _style = newValue }
        }
        var text = ""

        override var objectName: String { DxfFileToken.entityTolerance }
        override var objectType: ObjectType { .tolerance }
        override var subclassMarker: String { DxfSubclassMarker.tolerance }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _style = document.dimensionStyles.resolve(style)
        }
    }

    final class ProxyEntity: Entity {
        var classNumber: Int32 = 0
        var drawingFormat: Int32 = 0
        var maintenanceVersion: Int32 = 0
        var originalDataFormatDxf = false
        var proxyClassId: Int32 = 498
        var version: Version = .unknown
        var binaryData = Data()
        var data = Data()

        override var objectName: String { DxfFileToken.entityProxyEntity }
        override var objectType: ObjectType { .acadProxyEntity }
        override var subclassMarker: String { DxfSubclassMarker.proxyEntity }
    }

    /// An entity type ACadSharp reads but this port does not model; kept with its DXF name so drawings report it.
    final class UnknownEntity: Entity {
        let dxfName: String
        init(dxfName: String) {
            self.dxfName = dxfName
            super.init()
        }

        override var objectName: String { dxfName }
        override var objectType: ObjectType { .undefined }
    }

    // ───────────────────────── Viewport ─────────────────────────

    final class Viewport: Entity {
        static let paperViewId: Int16 = 1

        var activeStatus: Int16 = 1
        var ambientLightColor = Color.byBlock
        var backClipPlane = 0.0
        var boundary: Entity?
        var brightness = 0.0
        var center = XYZ.zero
        var circleZoomPercent: Int16 = 0
        var contrast = 0.0
        var defaultLightingType: UInt8 = 0
        var displayUcsIcon = false
        var elevation = 0.0
        var frontClipPlane = 0.0
        var frozenLayers: [Layer] = []
        var gridSpacing = XY.zero
        var height = 0.0
        var lensLength = 0.0
        var majorGridLineFrequency: Int16 = 0
        var namedUcs: UCS?
        var baseUcs: UCS?
        var renderMode: UInt8 = 0
        /// `ShadePlotMode` (170).
        var shadePlotMode: Int16 = 0
        var snapAngle = 0.0
        var snapBase = XY.zero
        var snapSpacing = XY.zero
        /// `ViewportStatusFlags` (90).
        var status: Int32 = 0
        var styleSheetName = ""
        var twistAngle = 0.0
        var ucsOrigin = XYZ.zero
        var ucsOrthographicType: Int16 = 0
        var ucsPerViewport = false
        var ucsXAxis = XYZ.axisX
        var ucsYAxis = XYZ.axisY
        var useDefaultLighting = false
        var viewCenter = XY.zero
        var viewDirection = XYZ.axisZ
        var viewHeight = 0.0
        var viewTarget = XYZ.zero
        var visualStyle: NonGraphicalObject?
        var width = 0.0
        var shadePlot: CadObject?
        var sunHandle: UInt64 = 0

        /// Position among the viewports of the owning block (`Id`).
        var id: Int16 {
            guard let record = owner as? BlockRecord else { return 0 }
            var n: Int16 = 0
            for entity in record.entities where entity is Viewport {
                n += 1
                if entity === self { return n }
            }
            return 0
        }

        /// The paper viewport of a layout.
        var representsPaper: Bool {
            guard let record = owner as? BlockRecord, let layout = record.layout else { return false }
            return layout.isPaperSpace && id == Viewport.paperViewId
        }

        override var objectName: String { DxfFileToken.entityViewport }
        override var objectType: ObjectType { .viewport }
        override var subclassMarker: String { DxfSubclassMarker.viewport }
    }
}
