// Symbol tables of the CAD document model (ACadSharp Tables): layers, line types, text and dimension styles,
// block records with their BLOCK / ENDBLK entities, applications, UCS, views and viewports.

import Foundation

extension ACad {
    /// `LayerFlags`.
    enum LayerFlags {
        static let frozen: Int16 = 1
        static let frozenNewViewports: Int16 = 2
        static let locked: Int16 = 4
    }

    /// `Layer`.
    final class Layer: TableEntry {
        static let defaultName = "0"
        static let defpointsName = "defpoints"

        static func makeDefault() -> Layer { Layer(name: defaultName) }
        static func makeDefpoints() -> Layer { let layer = Layer(name: defpointsName); layer.plotFlag = false; return layer }

        /// Never ByLayer / ByBlock; the default is colour 7.
        var color = Color(index: 7)
        var isOn = true
        private var _lineType: LineType?
        /// Continuous unless set.
        var lineType: LineType {
            get {
                if let lineType = _lineType { return lineType }
                let lineType = LineType(name: LineType.continuousName)
                _lineType = lineType
                return lineType
            }
            set { _lineType = newValue }
        }
        var lineWeight: LineWeight = .default
        var material: NonGraphicalObject?
        private var _plotFlag = true
        /// The Defpoints layer never plots.
        var plotFlag: Bool {
            get { name.caseInsensitiveCompare(Layer.defpointsName) == .orderedSame ? false : _plotFlag }
            set { _plotFlag = newValue }
        }
        /// Handle of the plot style name object (390).
        var plotStyleName: UInt64 = 0

        var isFrozen: Bool { flags & LayerFlags.frozen != 0 }

        override var objectName: String { DxfFileToken.tableLayer }
        override var objectType: ObjectType { .layer }
        override var subclassMarker: String { DxfSubclassMarker.layer }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _lineType = document.lineTypes.resolve(lineType)
        }
    }

    /// `LineTypeShapeFlags`.
    enum LineTypeShapeFlags {
        static let rotationIsAbsolute: Int16 = 1
        static let text: Int16 = 2
        static let shape: Int16 = 4
    }

    /// `LineType`.
    final class LineType: TableEntry {
        static let byBlockName = "ByBlock"
        static let byLayerName = "ByLayer"
        static let continuousName = "Continuous"

        static func makeByLayer() -> LineType { LineType(name: byLayerName) }
        static func makeByBlock() -> LineType { LineType(name: byBlockName) }

        /// `LineType.Segment`: a dash (> 0), gap (< 0) or dot (0), optionally with a shape or text.
        final class Segment {
            var flags: Int16 = 0
            var length = 0.0
            var offset = XY.zero
            var rotation = 0.0
            var scale = 1.0
            var shapeNumber: Int16 = 0
            var style: TextStyle?
            var text = ""
            weak var owner: LineType?

            init(length: Double = 0) { self.length = length }

            var isShape: Bool { flags & LineTypeShapeFlags.shape != 0 }
            var isText: Bool { flags & LineTypeShapeFlags.text != 0 }
        }

        var alignment: Character = "A"
        var description: String?
        private(set) var segments: [Segment] = []

        var isComplex: Bool { !segments.isEmpty }
        var hasShapes: Bool { segments.contains { $0.isShape } }
        var patternLength: Double { segments.reduce(0) { $0 + abs($1.length) } }

        func addSegment(_ segment: Segment) {
            if let style = segment.style, let document { segment.style = document.textStyles.resolve(style) }
            segment.owner = self
            segments.append(segment)
        }

        override var objectName: String { DxfFileToken.tableLinetype }
        override var objectType: ObjectType { .ltype }
        override var subclassMarker: String { DxfSubclassMarker.linetype }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            for segment in segments {
                if let style = segment.style { segment.style = document.textStyles.resolve(style) }
            }
        }
    }

    /// `FontFlags` of TrueType text styles.
    enum FontFlags {
        static let regular: Int32 = 0
        static let italic: Int32 = 1
        static let bold: Int32 = 2
    }

    /// `StyleFlags`.
    enum StyleFlags {
        static let isShape: Int16 = 1
        static let verticalText: Int16 = 4
    }

    /// `TextMirrorFlag`.
    enum TextMirrorFlag {
        static let backward: Int16 = 2
        static let upsideDown: Int16 = 4
    }

    /// `TextStyle`.
    final class TextStyle: TableEntry {
        static let defaultName = "Standard"
        static func makeDefault() -> TextStyle { TextStyle(name: defaultName) }

        var bigFontFilename: String?
        var filename = ""
        var height = 0.0
        var lastHeight = 0.0
        /// `TextMirrorFlag` (71).
        var mirrorFlag: Int16 = 0
        var obliqueAngle = 0.0
        /// `FontFlags` of a TrueType font (XDATA 1071).
        var trueType: Int32 = FontFlags.regular
        var width = 1.0

        var isShapeFile: Bool { flags & StyleFlags.isShape != 0 }

        override var objectName: String { DxfFileToken.tableStyle }
        override var objectType: ObjectType { .style }
        override var subclassMarker: String { DxfSubclassMarker.textStyle }
    }

    /// `AppId`.
    final class AppId: TableEntry {
        static let defaultName = "ACAD"
        static let blockRepBTag = "AcDbBlockRepBTag"
        static let blockRepETag = "AcDbBlockRepETag"

        override var objectName: String { DxfFileToken.tableAppId }
        override var objectType: ObjectType { .appid }
        override var subclassMarker: String { DxfSubclassMarker.applicationId }
    }

    /// `DimensionStyle`: every DIMxxx variable with ACadSharp's defaults.
    final class DimensionStyle: TableEntry {
        static let defaultName = "Standard"
        static let styleOverrideEntryName = "DSTYLE"
        static func makeDefault() -> DimensionStyle { DimensionStyle(name: defaultName) }

        /// The validating setters of ScaleFactor / ArrowSize / TextHeight (`ArgumentOutOfRangeException`).
        func setScaleFactor(_ value: Double) throws {
            guard value >= 0 else { throw Self.outOfRange("The ScaleFactor must be equals or greater than zero.", value) }
            scaleFactor = value
        }

        func setArrowSize(_ value: Double) throws {
            guard value >= 0 else { throw Self.outOfRange("The ArrowSize must be equals or greater than zero.", value) }
            arrowSize = value
        }

        func setTextHeight(_ value: Double) throws {
            guard value > 0 else { throw Self.outOfRange("The TextHeight must be greater than zero.", value) }
            textHeight = value
        }

        private static func outOfRange(_ message: String, _ value: Double) -> DwgError {
            DwgError("\(message) (Parameter 'value')\nActual value was \(DxfNumber.netString(value)).")
        }

        var alternateDimensioningSuffix = "[]"
        var alternateUnitDecimalPlaces: Int16 = 3
        var alternateUnitDimensioning = false
        var alternateUnitFormat: Int16 = 2 // LinearUnitFormat.Decimal
        var alternateUnitRounding = 0.0
        var alternateUnitScaleFactor = 25.4
        var alternateUnitToleranceDecimalPlaces: Int16 = 3
        var alternateUnitToleranceZeroHandling: UInt8 = 0 // SuppressZeroFeetAndInches
        var alternateUnitZeroHandling: UInt8 = 0
        var angularDecimalPlaces: Int16 = 0
        var angularUnit: Int16 = 0 // DecimalDegrees
        var angularZeroHandling: UInt8 = 0 // DisplayAll
        var arcLengthSymbolPosition: Int16 = 0
        var arrowBlock: BlockRecord?
        var arrowSize = 0.18
        var centerMarkSize = 0.09
        var cursorUpdate = false
        var decimalPlaces: Int16 = 2
        var decimalSeparator: UInt16 = 46 // "."
        var dimArrow1: BlockRecord?
        var dimArrow2: BlockRecord?
        var dimensionFit: Int16 = 0
        var dimensionLineColor: Color = .byBlock
        var dimensionLineExtension = 0.0
        var dimensionLineGap = 0.625
        var dimensionLineIncrement = 3.75
        var dimensionLineWeight: LineWeight = .byBlock
        var dimensionTextArrowFit: UInt8 = 3 // BestFit
        var dimensionUnit: Int16 = 2
        var extensionLineColor: Color = .byBlock
        var extensionLineExtension = 1.25
        var extensionLineOffset = 0.625
        var extensionLineWeight: LineWeight = .byBlock
        var fixedExtensionLineLength = 1.0
        var fractionFormat: Int16 = 0 // Horizontal
        var generateTolerances = false
        var isExtensionLineLengthFixed = false
        var joggedRadiusDimensionTransverseSegmentAngle = Double.pi / 4
        var leaderArrow: BlockRecord?
        var limitsGeneration = false
        var linearScaleFactor = 1.0
        var linearUnitFormat: Int16 = 2 // Decimal
        var lineType: LineType?
        var lineTypeExt1: LineType?
        var lineTypeExt2: LineType?
        var minusTolerance = 0.0
        var plusTolerance = 0.0
        var postFix = "<>"
        var rounding = 0.0
        var scaleFactor = 1.0
        var separateArrowBlocks = false
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
        var suppressFirstDimensionLine = false
        var suppressFirstExtensionLine = false
        var suppressOutsideExtensions = false
        var suppressSecondDimensionLine = false
        var suppressSecondExtensionLine = false
        var textBackgroundColor: Color = .byBlock
        var textBackgroundFillMode: Int16 = 0
        var textColor: Color = .byBlock
        var textDirection: UInt8 = 0
        var textHeight = 0.18
        var textHorizontalAlignment: UInt8 = 0 // Centered
        var textInsideExtensions = false
        var textInsideHorizontal = false
        var textMovement: Int16 = 0
        var textOutsideExtensions = false
        var textOutsideHorizontal = false
        var textVerticalAlignment: Int32 = 1 // Above
        var textVerticalPosition = 0.0
        var tickSize = 0.0
        var toleranceAlignment: UInt8 = 0 // Bottom
        var toleranceDecimalPlaces: Int16 = 2
        var toleranceScaleFactor = 1.0
        var toleranceZeroHandling: UInt8 = 8 // SuppressDecimalTrailingZeroes
        var zeroHandling: UInt8 = 8
        var altMzf = 0.0
        var altMzs = ""
        var mzf = 0.0
        var mzs = ""

        /// Text before "<>" in `postFix`.
        var prefix: String { splitPostFix().prefix }
        /// Text after "<>" in `postFix` (all of it without a "<>").
        var suffix: String { splitPostFix().suffix }

        private func splitPostFix() -> (prefix: String, suffix: String) {
            let chars = Array(postFix)
            for i in 0..<chars.count where chars[i] == "<" && i + 1 < chars.count && chars[i + 1] == ">" {
                return (String(chars[..<i]), String(chars[(i + 2)...]))
            }
            return ("", postFix)
        }

        /// `ApplyRounding`.
        func applyRounding(_ value: Double, isAlternate: Bool = false) -> Double {
            let r = isAlternate ? alternateUnitRounding : rounding
            return r != 0 ? r * (value / r).rounded(.toNearestOrEven) : value
        }

        override var objectName: String { DxfFileToken.tableDimstyle }
        override var objectType: ObjectType { .dimstyle }
        override var subclassMarker: String { DxfSubclassMarker.dimensionStyle }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _style = document.textStyles.resolve(style)
            lineType = lineType.map { document.lineTypes.resolve($0) }
            lineTypeExt1 = lineTypeExt1.map { document.lineTypes.resolve($0) }
            lineTypeExt2 = lineTypeExt2.map { document.lineTypes.resolve($0) }
            leaderArrow = leaderArrow.map { document.blockRecords.resolve($0) }
            dimArrow1 = dimArrow1.map { document.blockRecords.resolve($0) }
            dimArrow2 = dimArrow2.map { document.blockRecords.resolve($0) }
            arrowBlock = arrowBlock.map { document.blockRecords.resolve($0) }
        }
    }

    /// `BlockTypeFlags`.
    enum BlockTypeFlags {
        static let anonymous: Int16 = 1
        static let nonConstantAttributeDefinitions: Int16 = 2
        static let xRef: Int16 = 4
        static let xRefOverlay: Int16 = 8
        static let xRefDependent: Int16 = 16
        static let xRefResolved: Int16 = 32
        static let referenced: Int16 = 64
    }

    /// `Block`: the BLOCK entity that opens a block definition.
    final class Block: Entity {
        var basePoint = XYZ.zero
        var comments: String?
        /// `BlockTypeFlags`.
        var blockFlags: Int16 = 0
        var isUnloaded = false
        var xRefPath: String?

        var blockOwner: BlockRecord? { owner as? BlockRecord }
        var name: String {
            get { blockOwner?.name ?? "" }
            set { blockOwner?.name = newValue }
        }

        override var objectName: String { DxfFileToken.block }
        override var objectType: ObjectType { .block }
        override var subclassMarker: String { DxfSubclassMarker.blockBegin }
    }

    /// `BlockEnd`: the ENDBLK entity.
    final class BlockEnd: Entity {
        override var objectName: String { DxfFileToken.endBlock }
        override var objectType: ObjectType { .endblk }
        override var subclassMarker: String { DxfSubclassMarker.blockEnd }
    }

    /// `BlockRecord`: a block definition (model and paper space included) and its entities.
    final class BlockRecord: TableEntry {
        static let anonymousPrefix = "*A"
        static let modelSpaceName = "*Model_Space"
        static let paperSpaceName = "*Paper_Space"

        private(set) var blockEntity: Block
        private(set) var blockEnd: BlockEnd
        private(set) var entities: CadObjectCollection<Entity>!
        var canScale = true
        var isExplodable = false
        var layout: Layout?
        var preview: Data?
        /// `UnitsType` of the block (DXF 70 of BLOCK_RECORD, DWG insertion units).
        var units: Int16 = 0

        required init(name: String) {
            blockEntity = Block()
            blockEnd = BlockEnd()
            super.init(name: name)
            blockEntity.owner = self
            blockEnd.owner = self
            entities = CadObjectCollection<Entity>(owner: self)
            entities.canRemove = { !(($0 as? Viewport)?.representsPaper ?? false) }
        }

        /// `ModelSpace`: a new model space record with its layout.
        static func makeModelSpace() -> BlockRecord {
            let record = BlockRecord(name: modelSpaceName)
            let layout = Layout()
            layout.name = Layout.modelLayoutName
            layout.associatedBlock = record
            return record
        }

        /// `PaperSpace`: a new paper space record with its layout and paper viewport.
        static func makePaperSpace() -> BlockRecord {
            let record = BlockRecord(name: paperSpaceName)
            let layout = Layout()
            layout.name = Layout.paperLayoutName
            layout.associatedBlock = record
            layout.updatePaperViewport()
            return record
        }

        func setBlockEntity(_ block: Block) {
            blockEntity = block
            block.owner = self
        }

        func setBlockEnd(_ end: BlockEnd) {
            blockEnd = end
            end.owner = self
        }

        /// The block flags live on the BLOCK entity.
        var blockFlags: Int16 {
            get { blockEntity.blockFlags }
            set { blockEntity.blockFlags = newValue }
        }

        var isAnonymous: Bool {
            get { blockFlags & BlockTypeFlags.anonymous != 0 }
            set { blockFlags = newValue ? blockFlags | BlockTypeFlags.anonymous : blockFlags & ~BlockTypeFlags.anonymous }
        }

        var attributeDefinitions: [AttributeDefinition] { entities.compactMap { $0 as? AttributeDefinition } }
        var hasAttributes: Bool { entities.contains { $0 is AttributeDefinition } }
        var viewports: [Viewport] { entities.compactMap { $0 as? Viewport } }

        var sortEntitiesTable: SortEntitiesTable? {
            xDictionary?.entry(SortEntitiesTable.dictionaryEntryName) as? SortEntitiesTable
        }

        override var objectName: String { DxfFileToken.tableBlockRecord }
        override var objectType: ObjectType { .blockHeader }
        override var subclassMarker: String { DxfSubclassMarker.blockRecord }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            entities.registerAll(in: document)
        }

        override func unassignDocument() {
            for entity in entities { document?.removeCadObject(entity) }
            super.unassignDocument()
        }
    }

    /// `OrthographicType`.
    enum OrthographicType {
        static let none: Int16 = 0
    }

    /// `UCS`.
    final class UCS: TableEntry {
        var origin = XYZ.zero
        var xAxis = XYZ.axisX
        var yAxis = XYZ.axisY
        var orthographicType: Int16 = 0
        var orthographicViewType: Int16 = 0
        var elevation = 0.0

        override var objectName: String { DxfFileToken.tableUcs }
        override var objectType: ObjectType { .ucs }
        override var subclassMarker: String { DxfSubclassMarker.ucs }
    }

    /// `View`.
    final class View: TableEntry {
        var height = 0.0
        var width = 0.0
        var lensLength = 0.0
        var frontClipping = 0.0
        var backClipping = 0.0
        var angle = 0.0
        /// `ViewModeType` (71).
        var viewMode: Int32 = 0
        var isUcsAssociated = false
        var isPlottable = false
        /// `RenderMode` (281).
        var renderMode: UInt8 = 0
        var center = XY.zero
        var direction = XYZ.zero
        var target = XYZ.zero
        var visualStyle: NonGraphicalObject?
        var ucsOrigin = XYZ.zero
        var ucsXAxis = XYZ.zero
        var ucsYAxis = XYZ.zero
        var ucsElevation = 0.0
        var ucsOrthographicType: Int16 = 0
        var namedUcs: UCS?
        var baseUcs: UCS?

        override var objectName: String { DxfFileToken.tableView }
        override var objectType: ObjectType { .view }
        override var subclassMarker: String { DxfSubclassMarker.view }
    }

    /// `VPort`.
    final class VPort: TableEntry {
        static let defaultName = "*Active"

        var bottomLeft = XY.zero
        var topRight = XY(1, 1)
        var center = XY.zero
        var snapBasePoint = XY.zero
        var snapSpacing = XY(0.5, 0.5)
        var gridSpacing = XY(10, 10)
        private var _direction = XYZ.axisZ
        /// View direction; ACadSharp 3.8 normalizes on every write, also per component while reading.
        var direction: XYZ {
            get { _direction }
            set { _direction = newValue.normalized() }
        }
        var target = XYZ.zero
        var viewHeight = 10.0
        var aspectRatio = 1.0
        var lensLength = 50.0
        var frontClippingPlane = 0.0
        var backClippingPlane = 0.0
        var snapRotation = 0.0
        var twistAngle = 0.0
        var circleZoomPercent: Int16 = 1000
        /// `RenderMode` (281): Optimized2D.
        var renderMode: UInt8 = 0
        /// `ViewModeType` (71): FrontClippingZ.
        var viewMode: Int32 = 16
        /// `UscIconType` (74): OnOrigin.
        var ucsIconDisplay: Int16 = 3
        var snapOn = false
        var showGrid = true
        var isometricSnap = false
        var snapIsoPair: Int16 = 0
        var origin = XYZ.zero
        var xAxis = XYZ.axisX
        var yAxis = XYZ.axisY
        var namedUcs: UCS?
        var baseUcs: UCS?
        var orthographicType: Int16 = 0
        var elevation = 0.0
        /// `GridFlags` (60): _1 | _2.
        var gridFlags: Int16 = 3
        var minorGridLinesPerMajorGridLine: Int16 = 5
        var visualStyle: NonGraphicalObject?
        var useDefaultLighting = true
        /// `DefaultLightingType` (282): TwoDistantLights.
        var defaultLighting: UInt8 = 1
        var brightness = 0.0
        var contrast = 0.0
        var ambientColor = Color.black

        override var objectName: String { DxfFileToken.tableVport }
        override var objectType: ObjectType { .vport }
        override var subclassMarker: String { DxfSubclassMarker.vPort }
    }

    // ───────────────────────── Tables ─────────────────────────

    final class AppIdsTable: Table<AppId> {
        override var objectName: String { DxfFileToken.tableAppId }
        override var objectType: ObjectType { .appidControlObj }
        override var defaultEntries: [String] { [AppId.defaultName] }
        override func defaultEntry() -> AppId? { self[AppId.defaultName] }
    }

    final class BlockRecordsTable: Table<BlockRecord> {
        override var objectName: String { DxfFileToken.tableBlockRecord }
        override var objectType: ObjectType { .blockControlObj }
        override var defaultEntries: [String] { [BlockRecord.modelSpaceName, BlockRecord.paperSpaceName] }

        /// Anonymous blocks whose name is taken get a new "*A" name.
        @discardableResult
        override func add(_ item: BlockRecord) -> Bool {
            if item.isAnonymous, let existing = self[item.name] {
                if existing === item { return false }
                item.name = createName(BlockRecord.anonymousPrefix)
            }
            return super.add(item)
        }
    }

    final class DimensionStylesTable: Table<DimensionStyle> {
        override var objectName: String { DxfFileToken.tableDimstyle }
        override var objectType: ObjectType { .dimstyleControlObj }
        override var defaultEntries: [String] { [DimensionStyle.defaultName] }
        override func defaultEntry() -> DimensionStyle? { self[DimensionStyle.defaultName] }
    }

    final class LayersTable: Table<Layer> {
        override var objectName: String { DxfFileToken.tableLayer }
        override var objectType: ObjectType { .layerControlObj }
        override var defaultEntries: [String] { [Layer.defaultName] }
        override func defaultEntry() -> Layer? { self[Layer.defaultName] }
    }

    final class LineTypesTable: Table<LineType> {
        override var objectName: String { DxfFileToken.tableLinetype }
        override var objectType: ObjectType { .ltypeControlObj }
        override var defaultEntries: [String] { [LineType.byLayerName, LineType.byBlockName, LineType.continuousName] }
        override func defaultEntry() -> LineType? { self[LineType.byLayerName] }
        var byLayer: LineType? { self[LineType.byLayerName] }
        var byBlock: LineType? { self[LineType.byBlockName] }
        var continuous: LineType? { self[LineType.continuousName] }
    }

    final class TextStylesTable: Table<TextStyle> {
        override var objectName: String { DxfFileToken.tableStyle }
        override var objectType: ObjectType { .styleControlObj }
        override var defaultEntries: [String] { [TextStyle.defaultName] }
        override func defaultEntry() -> TextStyle? { self[TextStyle.defaultName] }
    }

    final class UCSTable: Table<UCS> {
        override var objectName: String { DxfFileToken.tableUcs }
        override var objectType: ObjectType { .ucsControlObj }
    }

    final class ViewsTable: Table<View> {
        override var objectName: String { DxfFileToken.tableView }
        override var objectType: ObjectType { .viewControlObj }
    }

    final class VPortsTable: Table<VPort> {
        override var objectName: String { DxfFileToken.tableVport }
        override var objectType: ObjectType { .vportControlObj }
        override var defaultEntries: [String] { [VPort.defaultName] }
        override func defaultEntry() -> VPort? { self[VPort.defaultName] }

        /// Several "*Active" viewports (one per tiled viewport) are kept, keyed by handle.
        @discardableResult
        override func add(_ item: VPort) -> Bool {
            insert(item, key: contains(item.name) ? "\(item.handle):\(item.name)" : item.name)
        }
    }
}
