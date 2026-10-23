// Non-graphical objects of the CAD document model (ACadSharp Objects): dictionaries and the objects stored in them
// (layouts, plot settings, styles, groups, xrecords, image / underlay definitions, scales, sort tables ...).

import Foundation

extension ACad {
    /// `DxfClass`: a CLASSES entry.
    final class DxfClass {
        static let defaultApplicationName = "ObjectDBX Classes"

        var applicationName = DxfClass.defaultApplicationName
        var classNumber: Int16 = 500
        var cppClassName = ""
        var dwgVersion: Int16 = 0
        var dxfName = ""
        var instanceCount: Int32 = 0
        /// 0x1F2 for entities, 0x1F3 for objects.
        var itemClassId: Int16 = 0x1F3
        var isAnEntity: Bool {
            get { itemClassId == 0x1F2 }
            set { itemClassId = newValue ? 0x1F2 : 0x1F3 }
        }
        var maintenanceVersion: Int16 = 0
        /// `ProxyFlags` (90).
        var proxyFlags: Int32 = 0
        var wasZombie = false

        init() {}

        init(_ cppClassName: String, _ dxfName: String, dwgVersion: Int16, itemClassId: Int16, maintenance: Int16,
             proxyFlags: Int32, application: String = DxfClass.defaultApplicationName) {
            self.cppClassName = cppClassName
            self.dxfName = dxfName
            self.dwgVersion = dwgVersion
            self.itemClassId = itemClassId
            maintenanceVersion = maintenance
            self.proxyFlags = proxyFlags
            applicationName = application
        }
    }

    /// `ProxyFlags` values used by the class definitions.
    enum ProxyFlags {
        static let none: Int32 = 0
        static let eraseAllowed: Int32 = 1
        static let transformAllowed: Int32 = 2
        static let colorChangeAllowed: Int32 = 4
        static let layerChangeAllowed: Int32 = 8
        static let linetypeChangeAllowed: Int32 = 16
        static let linetypeScaleChangeAllowed: Int32 = 32
        static let visibilityChangeAllowed: Int32 = 64
        static let cloningAllowed: Int32 = 128
        static let disablesProxyWarningDialog: Int32 = 1024
        static let r13FormatProxy: Int32 = 32768
    }

    /// `DxfClassCollection`: CLASSES by DXF name (`OrdinalIgnoreCase`), in .NET dictionary order.
    final class DxfClassCollection: Sequence {
        private var map = NameMap<DxfClass>()

        var entries: [DxfClass] { map.values }
        var count: Int { map.count }
        func makeIterator() -> IndexingIterator<[DxfClass]> { map.values.makeIterator() }

        subscript(name: String) -> DxfClass? { map[name] }

        /// `TryAdd` (`Add` throws for a duplicate name).
        @discardableResult
        func add(_ item: DxfClass) -> Bool { map.add(item.dxfName, item) }

        @discardableResult
        func remove(_ item: DxfClass) -> Bool { map.remove(item.dxfName) != nil }

        func byClassNumber(_ number: Int16) -> DxfClass? { map.values.first { $0.classNumber == number } }

        func clear() { map.removeAll() }

        /// `IncreaseInstanceCount`.
        func increaseInstanceCount(_ item: DxfClass) {
            if let existing = self[item.dxfName] {
                existing.instanceCount += 1
            } else {
                add(item)
                item.instanceCount = 1
            }
        }

        /// `ResetClassNumbers`: 500, 501 … in order.
        func resetClassNumbers() {
            for (i, item) in entries.enumerated() { item.classNumber = Int16(500 + i) }
        }
    }

    /// Objects that need a CLASSES entry (`IDxfClassDefined`).
    protocol DxfClassDefined: AnyObject {
        func dxfClass() -> DxfClass
    }

    // ───────────────────────── Dictionaries ─────────────────────────

    /// `DictionaryCloningFlags`.
    enum DictionaryCloningFlags {
        static let notApplicable: Int16 = 0, keepExisting: Int16 = 1
    }

    /// `CadDictionary`: named entries in insertion order (names compared without case).
    class CadDictionary: NonGraphicalObject {
        static let acadColor = "ACAD_COLOR"
        static let acadFieldList = "ACAD_FIELDLIST"
        static let acadGroup = "ACAD_GROUP"
        static let acadImageDict = "ACAD_IMAGE_DICT"
        static let acadLayout = "ACAD_LAYOUT"
        static let acadMaterial = "ACAD_MATERIAL"
        static let acadMLeaderStyle = "ACAD_MLEADERSTYLE"
        static let acadMLineStyle = "ACAD_MLINESTYLE"
        static let acadPdfDefinitions = "ACAD_PDFDEFINITIONS"
        static let acadPlotSettings = "ACAD_PLOTSETTINGS"
        static let acadPlotStyleName = "ACAD_PLOTSTYLENAME"
        static let acadScaleList = "ACAD_SCALELIST"
        static let acadSortEnts = "ACAD_SORTENTS"
        static let acadTableStyle = "ACAD_TABLESTYLE"
        static let acadVisualStyle = "ACAD_VISUALSTYLE"
        static let geographicData = "ACAD_GEOGRAPHICDATA"
        static let root = "ROOT"
        static let variableDictionary = "AcDbVariableDictionary"

        /// `DictionaryCloningFlags` (281).
        var cloningFlags: Int16 = 0
        var hardOwnerFlag = false
        private var map = NameMap<NonGraphicalObject>()

        override var objectName: String { DxfFileToken.objectDictionary }
        override var objectType: ObjectType { .dictionary }
        override var subclassMarker: String { DxfSubclassMarker.dictionary }

        var entries: [(name: String, object: NonGraphicalObject)] { map.pairs.map { ($0.key, $0.value) } }
        var count: Int { map.count }
        var isEmpty: Bool { map.isEmpty }
        var entryNames: [String] { map.keys }
        var values: [NonGraphicalObject] { map.values }

        func entry(_ name: String) -> NonGraphicalObject? { map[name] }
        func containsKey(_ name: String) -> Bool { map.containsKey(name) }

        /// `Add(key, value)`; false where ACadSharp throws (empty or duplicate key).
        @discardableResult
        func add(_ key: String, _ value: NonGraphicalObject) -> Bool {
            guard !key.isEmpty, map.add(key, value) else { return false }
            value.owner = self
            if let dictionary = value as? CadDictionary {
                document?.registerCollection(dictionary)
            } else {
                document?.addCadObject(value)
            }
            return true
        }

        @discardableResult
        func add(_ value: NonGraphicalObject) -> Bool { add(value.name, value) }

        @discardableResult
        func tryAdd(_ value: NonGraphicalObject) -> Bool {
            guard !containsKey(value.name) else { return false }
            return add(value.name, value)
        }

        @discardableResult
        func remove(_ key: String) -> NonGraphicalObject? {
            guard let item = map.remove(key) else { return nil }
            item.owner = nil
            if let dictionary = item as? CadDictionary {
                document?.unregisterCollection(dictionary)
            } else {
                document?.removeCadObject(item)
            }
            return item
        }

        /// `onEntryNameChanged`.
        func entryRenamed(_ entry: NonGraphicalObject, from oldName: String) {
            guard map[oldName] === entry, map.add(entry.name, entry) else { return }
            map.remove(oldName)
        }

        /// `CreateDefaultEntries`.
        static func createDefaultEntries(_ root: CadDictionary) {
            for name in [acadColor, acadGroup, acadLayout, acadMaterial, acadSortEnts, acadMLeaderStyle, acadMLineStyle,
                         acadTableStyle, acadPlotSettings, variableDictionary, acadScaleList, acadVisualStyle, acadFieldList,
                         acadImageDict] {
                root.tryAdd(CadDictionary(name: name))
            }
        }

        static func createRoot() -> CadDictionary {
            let root = CadDictionary(name: CadDictionary.root)
            createDefaultEntries(root)
            return root
        }

        /// Entries join the document with their dictionary (`RegisterCollection` walks them).
        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            for entry in values { document.addCadObject(entry) }
        }
    }

    final class CadDictionaryWithDefault: CadDictionary, DxfClassDefined {
        var defaultEntry: CadObject?

        override var objectName: String { DxfFileToken.objectDictionaryWithDefault }
        override var subclassMarker: String { DxfSubclassMarker.dictionaryWithDefault }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.dictionaryWithDefault, DxfFileToken.objectDictionaryWithDefault, dwgVersion: 22,
                     itemClassId: 499, maintenance: 42, proxyFlags: ProxyFlags.r13FormatProxy)
        }
    }

    final class DictionaryVariable: NonGraphicalObject, DxfClassDefined {
        static let currentAnnotationScale = "CANNOSCALE"
        static let currentMultiLeaderStyle = "CMLEADERSTYLE"
        static let currentTableStyle = "CTABLESTYLE"
        static let wipeoutFrame = "WIPEOUTFRAME"

        var objectSchemaNumber: Int32 = 0
        var value = ""

        init(name: String, value: String) {
            self.value = value
            super.init(name: name)
        }

        override init(name: String = "") { super.init(name: name) }

        override var objectName: String { DxfFileToken.objectDictionaryVar }
        override var subclassMarker: String { DxfSubclassMarker.dictionaryVariables }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.dictionaryVar, DxfFileToken.objectDictionaryVar, dwgVersion: 20, itemClassId: 499,
                     maintenance: 0, proxyFlags: ProxyFlags.none)
        }
    }

    /// `ObjectDictionaryCollection<T>`: a typed view of one of the root dictionary's entries.
    final class ObjectCollection<T: NonGraphicalObject>: Sequence {
        let dictionary: CadDictionary
        init(_ dictionary: CadDictionary) { self.dictionary = dictionary }

        func makeIterator() -> IndexingIterator<[T]> { dictionary.values.compactMap { $0 as? T }.makeIterator() }
        subscript(name: String) -> T? { dictionary.entry(name) as? T }
        func add(_ item: T) { dictionary.add(item) }
        func containsKey(_ name: String) -> Bool { dictionary.containsKey(name) }

        @discardableResult
        func tryAdd(_ item: T) -> T {
            if let existing = self[item.name] { return existing }
            add(item)
            return item
        }

        /// `UpdateReference`.
        func resolve(_ item: T) -> T {
            if item.document === dictionary.document, self[item.name] === item { return item }
            return tryAdd(item)
        }
    }

    // ───────────────────────── Layouts and plot settings ─────────────────────────

    /// `PlotFlags`.
    enum PlotFlags {
        static let useStandardScale: Int16 = 16, plotPlotStyles: Int16 = 32, printLineweights: Int16 = 128
        static let drawViewportsFirst: Int16 = 512
    }

    /// `PaperMargin`.
    struct PaperMargin: Equatable {
        var left = 0.0, bottom = 0.0, right = 0.0, top = 0.0
    }

    class PlotSettings: NonGraphicalObject, DxfClassDefined {
        var denominatorScale = 1.0
        /// `PlotFlags` (70).
        var flags: Int16 = PlotFlags.drawViewportsFirst | PlotFlags.printLineweights | PlotFlags.plotPlotStyles | PlotFlags.useStandardScale
        var numeratorScale = 1.0
        var pageName = "none_device"
        var paperHeight = 210.0
        var paperImageOriginX = 0.0
        var paperImageOriginY = 0.0
        /// `PlotRotation` (73).
        var paperRotation: Int16 = 0
        var paperSize = "ISO_A4_(210.00_x_297.00_MM)"
        /// `PlotPaperUnits` (72): millimetres.
        var paperUnits: Int16 = 1
        var paperWidth = 297.0
        var plotOriginX = 0.0
        var plotOriginY = 0.0
        /// `PlotType` (74): drawing extents.
        var plotType: Int16 = 1
        var plotViewName: String?
        /// `ScaledType` (75).
        var scaledFit: Int16 = 0
        var shadePlotDPI: Int16 = 300
        var shadePlotIDHandle: UInt64 = 0
        /// `ShadePlotMode` (76).
        var shadePlotMode: Int16 = 0
        /// `ShadePlotResolutionMode` (77).
        var shadePlotResolutionMode: Int16 = 0
        var standardScale = 1.0
        var styleSheet: String?
        var systemPrinterName: String?
        var unprintableMargin = PaperMargin()
        var windowLowerLeftX = 0.0
        var windowLowerLeftY = 0.0
        var windowUpperLeftX = 0.0
        var windowUpperLeftY = 0.0

        var printScale: Double { numeratorScale / denominatorScale }

        override var objectName: String { DxfFileToken.objectPlotSettings }
        override var subclassMarker: String { DxfSubclassMarker.plotSettings }

        func dxfClass() -> DxfClass { plotSettingsClass() }

        /// Layouts re-implement the interface with their own class.
        func plotSettingsClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.plotSettings, DxfFileToken.objectPlotSettings, dwgVersion: Version.ac1015.rawValue,
                     itemClassId: 499, maintenance: 42, proxyFlags: ProxyFlags.none)
        }
    }

    final class Layout: PlotSettings {
        override func plotSettingsClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.layout, DxfFileToken.objectLayout, dwgVersion: 0, itemClassId: 499, maintenance: 0,
                     proxyFlags: ProxyFlags.none)
        }

        static let modelLayoutName = "Model"
        static let paperLayoutName = "Layout1"

        /// The layout's block record (model space or a paper space block). Weak: the record points back.
        weak var associatedBlock: BlockRecord? {
            didSet { associatedBlock?.layout = self }
        }
        var associatedBlockHandle: UInt64 = 0
        var baseUCS: UCS?
        var elevation = 0.0
        var insertionBasePoint = XYZ.zero
        weak var lastActiveViewport: Viewport?
        /// `LayoutFlags` (70): paper space linetype scaling.
        var layoutFlags: Int16 = 1
        var maxExtents = XYZ(231.3, 175.5, 0)
        var maxLimits = XY(277.0, 202.5)
        var minExtents = XYZ(25.7, 19.5, 0)
        var minLimits = XY(-20.0, -7.5)
        var origin = XYZ.zero
        var tabOrder: Int32 = 0
        var ucs: UCS?
        var ucsOrthographicType: Int16 = 0
        var xAxis = XYZ.axisX
        var yAxis = XYZ.axisY
        /// Keeps a layout created with its own block alive (`Layout(name)` / `ModelSpace`).
        var ownedBlock: BlockRecord?

        var isPaperSpace: Bool { name.caseInsensitiveCompare(Layout.modelLayoutName) != .orderedSame }
        var viewports: [Viewport] { associatedBlock?.viewports ?? [] }
        var paperViewport: Viewport? { viewports.first }

        override var objectName: String { DxfFileToken.objectLayout }
        override var objectType: ObjectType { .layout }
        override var subclassMarker: String { DxfSubclassMarker.layout }

        override func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.layout, DxfFileToken.objectLayout, dwgVersion: 0, itemClassId: 499, maintenance: 0,
                     proxyFlags: ProxyFlags.none)
        }

        /// `UpdatePaperViewport`.
        func updatePaperViewport() {
            guard isPaperSpace, let block = associatedBlock else { return }
            if paperViewport == nil { block.entities.add(Viewport()) }
            guard let viewport = paperViewport else { return }
            viewport.height = paperHeight
            viewport.width = paperWidth
            viewport.center = XYZ(viewport.width / 2, viewport.height / 2, 0)
        }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            if let block = associatedBlock, !document.blockRecords.contains(block.name) || document.blockRecords[block.name] !== block {
                document.blockRecords.add(block)
            }
            ownedBlock = nil
        }
    }

    // ───────────────────────── Styles ─────────────────────────

    final class MLineStyle: NonGraphicalObject {
        static let defaultName = "Standard"

        final class Element {
            var color = Color.byLayer
            var lineType: LineType = LineType.makeByLayer()
            var offset = 0.0
        }

        var description: String?
        private(set) var elements: [Element] = []
        var endAngle = Double.pi / 2
        var fillColor = Color.byLayer
        /// `MLineStyleFlags` (70).
        var flags: Int16 = 0
        var startAngle = Double.pi / 2

        func addElement(_ element: Element) {
            if let document { element.lineType = document.lineTypes.resolve(element.lineType) }
            elements.append(element)
        }

        static func makeDefault() -> MLineStyle {
            let style = MLineStyle(name: defaultName)
            style.startAngle = MathHelper.halfPI
            style.endAngle = MathHelper.halfPI
            let a = Element()
            a.offset = 0.5
            style.addElement(a)
            let b = Element()
            b.offset = -0.5
            style.addElement(b)
            return style
        }

        override var objectName: String { DxfFileToken.objectMLineStyle }
        override var objectType: ObjectType { .mlinestyle }
        override var subclassMarker: String { DxfSubclassMarker.mLineStyle }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            for element in elements { element.lineType = document.lineTypes.resolve(element.lineType) }
        }
    }

    final class MultiLeaderStyle: NonGraphicalObject, DxfClassDefined {
        static let defaultName = "Standard"

        var alignSpace = 0.0
        var arrowhead: BlockRecord?
        var arrowheadSize = 0.18
        var blockContent: BlockRecord?
        var blockContentColor = Color.byBlock
        var blockContentConnection: Int16 = 0
        var blockContentRotation = 0.0
        var blockContentScale = XYZ(1)
        var breakGapSize = 0.125
        /// `LeaderContentType` (170): MText.
        var contentType: Int16 = 2
        var defaultTextContents = ""
        var description = ""
        var enableBlockContentRotation = false
        var enableBlockContentScale = false
        var enableDogleg = true
        var enableLanding = true
        var firstSegmentAngleConstraint = 0.0
        var isAnnotative = false
        var landingDistance = 0.36
        var landingGap = 0.09
        var leaderDrawOrder: Int16 = 0
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
        var leaderLineWeight: LineWeight = .byBlock
        var lineColor = Color.byBlock
        var maxLeaderSegmentsPoints: Int32 = 2
        var multiLeaderDrawOrder: Int16 = 0
        var overwritePropertyValue = false
        var pathType: Int16 = 0
        var scaleFactor = 1.0
        var secondSegmentAngleConstraint = 0.0
        var textAlignAlwaysLeft = false
        var textAlignment: Int16 = 0
        /// `TextAngleType` (175): horizontal.
        var textAngle: Int16 = 1
        var textAttachmentDirection: Int16 = 0
        var textBottomAttachment: Int16 = 0
        var textColor = Color.byBlock
        var textFrame = false
        var textHeight = 0.18
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
        var unknownFlag298 = false

        override var objectName: String { DxfFileToken.objectMLeaderStyle }
        override var subclassMarker: String { DxfSubclassMarker.mLeaderStyle }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.mLeaderStyle, DxfFileToken.objectMLeaderStyle, dwgVersion: Version.ac1021.rawValue,
                     itemClassId: 499, maintenance: 25, proxyFlags: 4095)
        }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _textStyle = document.textStyles.resolve(textStyle)
            _leaderLineType = document.lineTypes.resolve(leaderLineType)
            arrowhead = arrowhead.map { document.blockRecords.resolve($0) }
            blockContent = blockContent.map { document.blockRecords.resolve($0) }
        }
    }

    /// `TableStyle`: ACAD_TABLESTYLE entries with their cell styles.
    final class TableStyle: NonGraphicalObject, DxfClassDefined {
        static let defaultName = "Standard"

        /// `CellEdgeFlags`.
        enum CellEdgeFlags {
            static let unknown: Int32 = 0, top: Int32 = 1, right: Int32 = 2, bottom: Int32 = 4, left: Int32 = 8
            static let insideVertical: Int32 = 16, insideHorizontal: Int32 = 32
        }

        /// `CellBorder`.
        final class CellBorder {
            var applyBorder = false
            var color = Color.byBlock
            var doubleLineSpacing = 0.0
            let edgeFlags: Int32
            var isInvisible = false
            var lineWeight: LineWeight = .byBlock
            /// `BorderPropertyFlags` (90).
            var propertyOverrideFlags: Int32 = 0
            /// `BorderType` (91): single.
            var type: Int16 = 1
            init(_ edgeFlags: Int32) { self.edgeFlags = edgeFlags }
        }

        /// `ContentFormat`.
        class ContentFormat {
            var alignment: Int32 = 0
            var color = Color.byBlock
            var hasData = false
            var propertyFlags: Int32 = 0
            /// `CellStylePropertyFlags` (91).
            var propertyOverrideFlags: Int32 = 0
            var rotation = 0.0
            var scale = 0.0
            var textHeight = 0.0
            /// A new "Standard" style per format, outside any document (`TextStyle.Default`).
            var textStyle: TextStyle? = TextStyle.makeDefault()
            var valueDataType: Int32 = 0
            var valueFormatString: String?
            var valueUnitType: Int32 = 0
            init() {}
        }

        /// `CellStyle`.
        final class CellStyle: ContentFormat {
            static let tableCellStyleName = "Table", dataCellStyleName = "_DATA"
            static let headerCellStyleName = "_HEADER", titleCellStyleName = "_TITLE"

            /// `CellStyleClass`.
            enum StyleClass { static let data: Int32 = 1, label: Int32 = 2 }

            static func makeDefaultDataCellStyle() -> CellStyle { CellStyle(dataCellStyleName, StyleClass.label, id: 3) }
            static func makeDefaultHeaderCellStyle() -> CellStyle { CellStyle(headerCellStyleName, StyleClass.data, id: 2) }
            static func makeDefaultTitleCellStyle() -> CellStyle { CellStyle(titleCellStyleName, StyleClass.data, id: 1) }
            static func makeDefaultTableCellStyle() -> CellStyle { CellStyle(tableCellStyleName, StyleClass.label, id: 4) }

            var backgroundColor = Color.byBlock
            var bottomBorder = CellBorder(CellEdgeFlags.bottom)
            var bottomMargin = 0.0
            /// `CellAlignmentType` (170).
            var cellAlignment: Int32 = 0
            var contentColor = Color.byBlock
            /// `CellContentLayoutFlags`.
            var contentLayoutFlags: Int32 = 0
            var horizontalInsideBorder = CellBorder(CellEdgeFlags.insideHorizontal)
            var horizontalMargin = 0.06
            var isFillColorOn = false
            var leftBorder = CellBorder(CellEdgeFlags.left)
            var marginHorizontalSpacing = 0.0
            /// `MarginFlags` (171).
            var marginOverrideFlags: Int32 = 0
            var marginVerticalSpacing = 0.0
            var name: String?
            var rightBorder = CellBorder(CellEdgeFlags.right)
            var rightMargin = 0.0
            /// `CellStyleClass` (91).
            var styleClass: Int32 = 0
            /// `CellStylePropertyFlags` (92).
            var tableCellStylePropertyFlags: Int32 = 0
            var textColor = Color.byBlock
            /// ACadSharp creates the top border with the right edge flag.
            var topBorder = CellBorder(CellEdgeFlags.right)
            /// `CellStyleType` (90).
            var type: Int32 = 0
            var verticalInsideBorder = CellBorder(CellEdgeFlags.insideVertical)
            var verticalMargin = 0.06
            var id: Int32 = 0

            override init() { super.init() }

            convenience init(_ name: String, _ styleClass: Int32, id: Int32) {
                self.init()
                self.name = name
                self.styleClass = styleClass
                self.id = id
                hasData = true
            }
        }

        var cellStyles: [CellStyle] = []
        var dataCellStyle = CellStyle.makeDefaultDataCellStyle()
        var description: String?
        var flags: Int16 = 0
        /// `TableFlowDirectionType` (70): down.
        var flowDirection: Int16 = 0
        var headerCellStyle = CellStyle.makeDefaultHeaderCellStyle()
        var horizontalCellMargin = 0.06
        var suppressHeaderRow = false
        var suppressTitle = false
        var tableCellStyle = CellStyle.makeDefaultTableCellStyle()
        var titleCellStyle = CellStyle.makeDefaultTitleCellStyle()
        var verticalCellMargin = 0.06

        override var objectName: String { DxfFileToken.objectTableStyle }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.tableStyle }

        static func makeDefault() -> TableStyle { TableStyle(name: defaultName) }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.tableStyle, DxfFileToken.objectTableStyle, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 499, maintenance: 0, proxyFlags: 4095)
        }
    }

    /// `Material`: render materials (written by the DWG writer, not by the DXF writer).
    final class Material: NonGraphicalObject, DxfClassDefined {
        static let byBlockName = "ByBlock", byLayerName = "ByLayer", globalName = "Global"
        /// `Matrix4.Identity`, 16 values in `Matrix4(double[])` order.
        static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

        /// `MaterialMap`: the values every map channel has.
        struct MapChannel {
            /// `AutoTransformMethodFlags`: no auto transform.
            var autoTransform: UInt8 = 1
            var blendFactor = 1.0
            var fileName: String?
            /// `MapSource`: use image file.
            var source: UInt8 = 1
            var matrix = Material.identity
            /// `ProjectionMethod`: planar.
            var projection: UInt8 = 1
            /// `TilingMethod`: tile.
            var tiling: UInt8 = 1
        }

        var ambientColor = Color.byBlock
        var ambientColorFactor = 1.0
        /// `ColorMethod`: current.
        var ambientColorMethod: UInt8 = 0
        var bump = MapChannel()
        /// `MaterialChannelFlags`: use diffuse.
        var channelFlags: Int32 = 1
        var description: String?
        var diffuse = MapChannel()
        var diffuseColor = Color.byBlock
        var diffuseColorFactor = 1.0
        var diffuseColorMethod: UInt8 = 0
        /// `MaterialIlluminationModel`: Blinn shader.
        var illuminationModel: Int32 = 0
        /// `MaterialMode`: realistic.
        var mode: Int32 = 0
        var opacity = 1.0
        var opacityMap = MapChannel()
        var reflection = MapChannel()
        var reflectivity = 0.0
        var refraction = MapChannel()
        var refractionIndex = 1.0
        var selfIllumination = 0.0
        var specular = MapChannel()
        var specularColor = Color.byBlock
        var specularColorFactor = 1.0
        var specularColorMethod: UInt8 = 0
        var specularGlossFactor = 0.5
        var translucence = 0.0

        override var objectName: String { DxfFileToken.objectMaterial }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.material }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.material, DxfFileToken.objectMaterial, dwgVersion: 0, itemClassId: 499, maintenance: 0,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    // ───────────────────────── Other objects ─────────────────────────

    final class Group: NonGraphicalObject {
        var description = ""
        var entities: [Entity] = []
        var selectable = true

        /// An automatically named group (null, white space or a "*" name).
        var isUnnamed: Bool { name.unicodeScalars.allSatisfy(\.properties.isWhitespace) || name.hasPrefix("*") }

        override var objectName: String { DxfFileToken.tableGroup }
        override var objectType: ObjectType { .group }
        override var subclassMarker: String { DxfSubclassMarker.group }
    }

    /// A DXF group value of an xrecord or a CAD value.
    enum DxfValue {
        case string(String)
        case double(Double)
        case int16(Int16)
        case int32(Int32)
        case int64(Int64)
        case byte(UInt8)
        case bool(Bool)
        case point(XYZ)
        case handle(UInt64)
        case bytes(Data)
    }

    final class XRecord: NonGraphicalObject {
        struct Entry {
            var code: Int
            var value: DxfValue
        }

        var cloningFlags: Int16 = 0
        var entries: [Entry] = []

        override var objectName: String { DxfFileToken.objectXRecord }
        override var objectType: ObjectType { .xrecord }
        override var subclassMarker: String { DxfSubclassMarker.xRecord }
    }

    final class AcdbPlaceHolder: NonGraphicalObject, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectPlaceholder }
        override var objectType: ObjectType { .acdbplaceholder }
        override var subclassMarker: String { DxfSubclassMarker.acDbPlaceHolder }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.acDbPlaceHolder, DxfFileToken.objectPlaceholder, dwgVersion: 0, itemClassId: 499,
                     maintenance: 0, proxyFlags: ProxyFlags.none)
        }
    }

    final class BookColor: NonGraphicalObject, DxfClassDefined {
        var color = Color.byBlock
        var colorName: String?
        var bookName: String?

        /// "BOOK$COLOR" from the two names; a name with a '$' sets both, any other name only the colour name.
        override var name: String {
            get {
                guard let colorName, !colorName.isEmpty else { return "" }
                return "\(bookName ?? "")$\(colorName)"
            }
            set {
                if newValue.contains("$") {
                    super.name = newValue
                    let parts = newValue.components(separatedBy: "$")
                    bookName = parts.first
                    colorName = parts.last
                } else {
                    colorName = newValue
                }
            }
        }

        override var objectName: String { DxfFileToken.objectDBColor }
        override var subclassMarker: String { DxfSubclassMarker.dbColor }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.dbColor, DxfFileToken.objectDBColor, dwgVersion: Version.ac1015.rawValue,
                     itemClassId: 499, maintenance: 14, proxyFlags: ProxyFlags.none)
        }
    }

    final class ImageDefinition: NonGraphicalObject, DxfClassDefined {
        var classVersion: Int32 = 0
        var defaultSize = XY(1, 1)
        var fileName = ""
        var isLoaded = true
        var size = XY.zero
        /// `ResolutionUnit` (281).
        var units: UInt8 = 0

        override var objectName: String { DxfFileToken.objectImageDefinition }
        override var subclassMarker: String { DxfSubclassMarker.rasterImageDef }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.rasterImageDef, DxfFileToken.objectImageDefinition, dwgVersion: 20, itemClassId: 499,
                     maintenance: 0, proxyFlags: ProxyFlags.none, application: "ISM")
        }
    }

    final class ImageDefinitionReactor: NonGraphicalObject, DxfClassDefined {
        var classVersion: Int32 = 2
        weak var image: RasterImage?

        override var objectName: String { DxfFileToken.objectImageDefinitionReactor }
        override var subclassMarker: String { DxfSubclassMarker.rasterImageDefReactor }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.rasterImageDefReactor, DxfFileToken.objectImageDefinitionReactor, dwgVersion: 20,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.eraseAllowed, application: "ISM")
        }
    }

    final class RasterVariables: NonGraphicalObject, DxfClassDefined {
        var classVersion: Int32 = 0
        /// `ImageDisplayQuality` (71): high.
        var displayQuality: Int16 = 1
        var isDisplayFrameShown = false
        /// `ImageUnits` (72).
        var units: Int16 = 0

        override var objectName: String { DxfFileToken.objectRasterVariables }
        override var subclassMarker: String { DxfSubclassMarker.rasterVariables }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.rasterVariables, DxfFileToken.objectRasterVariables, dwgVersion: 20, itemClassId: 499,
                     maintenance: 0, proxyFlags: ProxyFlags.none, application: "ISM")
        }
    }

    final class WipeoutVariables: NonGraphicalObject, DxfClassDefined {
        var displayFrame = false

        override var objectName: String { DxfFileToken.objectWipeoutVariables }
        override var subclassMarker: String { DxfSubclassMarker.wipeoutVariables }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.wipeoutVariables, DxfFileToken.objectWipeoutVariables, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.none,
                     application: "\"WipeOut|Product Desc: WipeOut Dbx Application|Company: Autodesk, Inc.|WEB Address: www.autodesk.com\"")
        }
    }

    final class Scale: NonGraphicalObject, DxfClassDefined {
        static let defaultName = "1:1"

        var drawingUnits = 0.0
        var isUnitScale = false
        var paperUnits = 0.0
        var scaleFactor: Double { paperUnits / drawingUnits }

        init(name: String, paper: Double, drawing: Double, isUnit: Bool) {
            paperUnits = paper
            drawingUnits = drawing
            isUnitScale = isUnit
            super.init(name: name)
        }

        override init(name: String = "") { super.init(name: name) }

        /// `Scale.Default`: a new 1:1 unit scale.
        static func makeDefault() -> Scale { Scale(name: defaultName, paper: 1, drawing: 1, isUnit: true) }

        override var objectName: String { DxfFileToken.objectScale }
        override var subclassMarker: String { DxfSubclassMarker.scale }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.scale, DxfFileToken.objectScale, dwgVersion: Version.ac1021.rawValue, itemClassId: 499,
                     maintenance: 1,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    final class SortEntitiesTable: NonGraphicalObject, DxfClassDefined {
        static let dictionaryEntryName = "ACAD_SORTENTS"

        struct Sorter {
            var sortHandle: UInt64
            var entity: Entity
        }

        weak var blockOwner: BlockRecord?
        private(set) var sorters: [Sorter] = []

        override var objectName: String { DxfFileToken.objectSortEntsTable }
        override var subclassMarker: String { DxfSubclassMarker.sortentsTable }

        func add(_ entity: Entity, sortHandle: UInt64) {
            sorters.append(Sorter(sortHandle: sortHandle, entity: entity))
        }

        /// `GetEnumerator`: every enumeration sorts the list in place with `List<T>.Sort()`, which is unstable for
        /// equal sort handles, so the order of a later enumeration can differ from the first.
        func enumerate() -> [Sorter] {
            netIntroSort(&sorters) { $0.sortHandle < $1.sortHandle }
            return sorters
        }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.sortentsTable, DxfFileToken.objectSortEntsTable, dwgVersion: Version.ac1014.rawValue,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.none)
        }
    }

    /// PDFDEFINITION (`UnderlayDefinition`).
    final class PdfUnderlayDefinition: NonGraphicalObject, DxfClassDefined {
        var file = ""
        var page = ""

        override var objectName: String { DxfFileToken.objectPdfDefinition }
        override var subclassMarker: String { DxfSubclassMarker.underlayDefinition }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.pdfDefinition, DxfFileToken.objectPdfDefinition, dwgVersion: 26, itemClassId: 499,
                     maintenance: 0,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    /// SPATIAL_FILTER (XCLIP boundary).
    final class SpatialFilter: NonGraphicalObject, Orientable, DxfClassDefined {
        static let spatialFilterEntryName = "SPATIAL"

        var backDistance = 0.0
        var boundaryPoints: [XY] = []
        var clipBackPlane = false
        var clipFrontPlane = false
        var displayBoundary = false
        var frontDistance = 0.0
        /// 4 × 3 matrices as read (row-major, 12 values each).
        var insertTransform: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
        var inverseInsertTransform: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]
        var normal = XYZ.axisZ
        var origin = XYZ.axisZ

        override var objectName: String { DxfFileToken.objectSpatialFilter }
        override var subclassMarker: String { DxfSubclassMarker.spatialFilter }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.spatialFilter, DxfFileToken.objectSpatialFilter, dwgVersion: 20, itemClassId: 499,
                     maintenance: 0, proxyFlags: ProxyFlags.none)
        }
    }

    // ───────────────────────── Multileader annotation context ─────────────────────────

    /// `MultiLeaderObjectContextData`: the geometry of a multileader (embedded in the MULTILEADER entity).
    final class MultiLeaderObjectContextData: AnnotScaleObjectContextData, DxfClassDefined {
        struct StartEndPointPair {
            var startPoint = XYZ.zero
            var endPoint = XYZ.zero
        }

        final class LeaderLine {
            var arrowhead: BlockRecord?
            var arrowheadSize = 0.0
            var breakInfoCount: Int32 = 0
            var segmentIndex: Int32 = 0
            var startEndPoints: [StartEndPointPair] = []
            var index: Int32 = 0
            var lineColor = Color.byBlock
            var lineType: LineType?
            var lineWeight: LineWeight = .w0
            /// `LeaderLinePropertOverrideFlags` (93).
            var overrideFlags: Int32 = 0
            var pathType: Int16 = 0
            var points: [XYZ] = []
        }

        final class LeaderRoot {
            var breakStartEndPointsPairs: [StartEndPointPair] = []
            var connectionPoint = XYZ.zero
            var contentValid = false
            var direction = XYZ.zero
            var landingDistance = 0.0
            var leaderIndex: Int32 = 0
            var lines: [LeaderLine] = []
            var textAttachmentDirection: Int16 = 0
            var unknown = false
        }

        var arrowheadSize = 0.0
        var backgroundFillColor = Color.byBlock
        var backgroundFillEnabled = false
        var backgroundMaskFillOn = false
        var backgroundScaleFactor = 0.0
        var backgroundTransparency: Int32 = 0
        var baseDirection = XYZ.zero
        var basePoint = XYZ.zero
        var baseVertical = XYZ.zero
        var blockContent: BlockRecord?
        var blockContentColor = Color.byBlock
        var blockContentConnection: Int16 = 0
        var blockContentLocation = XYZ.zero
        var blockContentNormal = XYZ.zero
        var blockContentRotation = 0.0
        var blockContentScale = XYZ.zero
        var boundaryHeight = 0.0
        var boundaryWidth = 0.0
        var columnFlowReversed = false
        var columnGutter = 0.0
        var columnSizes: [Double] = []
        var columnType: Int16 = 0
        var columnWidth = 0.0
        var contentBasePoint = XYZ.zero
        var direction = XYZ.zero
        var flowDirection: Int16 = 0
        var hasContentsBlock = false
        var hasTextContents = false
        var landingGap = 0.0
        var leaderRoots: [LeaderRoot] = []
        var lineSpacing: Int16 = 0
        var lineSpacingFactor = 0.0
        var normalReversed = false
        var scaleFactor = 0.0
        var textAlignment: Int16 = 0
        var textAttachmentPoint: Int16 = 0
        var textBottomAttachment: Int16 = 0
        var textColor = Color.byBlock
        var textHeight = 0.0
        var textHeightAutomatic = false
        var textLabel = ""
        var textLeftAttachment: Int16 = 0
        var textLocation = XYZ.zero
        var textNormal = XYZ.zero
        var textRightAttachment: Int16 = 0
        var textRotation = 0.0
        var textStyle: TextStyle?
        var textTopAttachment: Int16 = 0
        /// 16 values in the DWG order M00, M10, M20, M30, M01 … M33 (a default `Matrix4` is all zeros).
        var transformationMatrix: [Double] = Array(repeating: 0, count: 16)
        var wordBreak = false

        override var objectName: String { DxfFileToken.objectMLeaderContextData }
        override var subclassMarker: String { DxfSubclassMarker.multiLeaderObjectContextData }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.multiLeaderObjectContextData, DxfFileToken.objectMLeaderContextData, dwgVersion: 0,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }
}

/// `GenericArraySortHelper<T>.IntrospectiveSort` (.NET 8 `List<T>.Sort()` for `IComparable<T>` items), ported exactly
/// so that items with equal keys end up in the same order as in ACadSharp.
func netIntroSort<T>(_ keys: inout [T], _ less: (T, T) -> Bool) {
    guard keys.count > 1 else { return }
    func swapIfGreater(_ i: Int, _ j: Int) {
        if less(keys[j], keys[i]) { keys.swapAt(i, j) }
    }
    func insertionSort(_ lo: Int, _ hi: Int) {
        var i = lo
        while i < hi {
            let t = keys[i + 1]
            var j = i
            while j >= lo && less(t, keys[j]) {
                keys[j + 1] = keys[j]
                j -= 1
            }
            keys[j + 1] = t
            i += 1
        }
    }
    func downHeap(_ lo: Int, _ start: Int, _ n: Int) {
        var i = start
        let d = keys[lo + i - 1]
        while i <= n >> 1 {
            var child = 2 * i
            if child < n && less(keys[lo + child - 1], keys[lo + child]) { child += 1 }
            if !less(d, keys[lo + child - 1]) { break }
            keys[lo + i - 1] = keys[lo + child - 1]
            i = child
        }
        keys[lo + i - 1] = d
    }
    func heapSort(_ lo: Int, _ n: Int) {
        var i = n >> 1
        while i >= 1 { downHeap(lo, i, n); i -= 1 }
        i = n
        while i > 1 {
            keys.swapAt(lo, lo + i - 1)
            downHeap(lo, 1, i - 1)
            i -= 1
        }
    }
    func pickPivotAndPartition(_ lo: Int, _ length: Int) -> Int {
        let last = lo + length - 1, middle = lo + ((length - 1) >> 1)
        swapIfGreater(lo, middle)
        swapIfGreater(lo, last)
        swapIfGreater(middle, last)
        let nextToLast = lo + length - 2
        let pivot = keys[middle]
        keys.swapAt(middle, nextToLast)
        var left = lo, right = nextToLast
        while left < right {
            while left < nextToLast { left += 1; if !less(keys[left], pivot) { break } }
            while right > lo { right -= 1; if !less(pivot, keys[right]) { break } }
            if left >= right { break }
            keys.swapAt(left, right)
        }
        if left != nextToLast { keys.swapAt(left, nextToLast) }
        return left - lo
    }
    func introSort(_ lo: Int, _ length: Int, _ depth: Int) {
        var depthLimit = depth
        var partitionSize = length
        while partitionSize > 1 {
            if partitionSize <= 16 {
                if partitionSize == 2 {
                    swapIfGreater(lo, lo + 1)
                } else if partitionSize == 3 {
                    swapIfGreater(lo, lo + 1)
                    swapIfGreater(lo, lo + 2)
                    swapIfGreater(lo + 1, lo + 2)
                } else {
                    insertionSort(lo, lo + partitionSize - 1)
                }
                return
            }
            if depthLimit == 0 {
                heapSort(lo, partitionSize)
                return
            }
            depthLimit -= 1
            let p = pickPivotAndPartition(lo, partitionSize)
            introSort(lo + p + 1, partitionSize - (p + 1), depthLimit)
            partitionSize = p
        }
    }
    introSort(0, keys.count, 2 * ((Int.bitWidth - 1 - keys.count.leadingZeroBitCount) + 1))
}
