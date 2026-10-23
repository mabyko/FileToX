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

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.plotSettings, DxfFileToken.objectPlotSettings, dwgVersion: Version.ac1015.rawValue,
                     itemClassId: 499, maintenance: 42, proxyFlags: ProxyFlags.none)
        }
    }

    final class Layout: PlotSettings {
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

    /// `TableStyle` with the three cell styles the writers use.
    final class TableStyle: NonGraphicalObject, DxfClassDefined {
        static let defaultName = "Standard"

        final class CellBorder {
            var color = Color.byBlock
            var lineWeight: LineWeight = .byBlock
            var isInvisible = false
            var doubleLineSpacing = 0.0
            /// `BorderPropertyFlags`.
            var propertyOverrideFlags: Int32 = 0
            var type: Int16 = 1
            var edgeFlags: Int32 = 0
            init(edge: Int32) { edgeFlags = edge }
        }

        final class CellStyle {
            var name = ""
            var textStyle: TextStyle?
            var textHeight = 0.0
            /// `CellAlignmentType` (170).
            var cellAlignment: Int16 = 0
            var contentColor = Color.byBlock
            var backgroundColor = Color.byBlock
            var textColor = Color.byBlock
            var isFillColorOn = false
            /// `CellStyleType` (90).
            var type: Int32 = 0
            /// Value data type (91).
            var valueDataType: Int32 = 0
            var topBorder = CellBorder(edge: 1)
            var horizontalInsideBorder = CellBorder(edge: 32)
            var bottomBorder = CellBorder(edge: 4)
            var leftBorder = CellBorder(edge: 8)
            var verticalInsideBorder = CellBorder(edge: 16)
            var rightBorder = CellBorder(edge: 2)
            var horizontalMargin = 0.06
            var verticalMargin = 0.06
            init(name: String = "") { self.name = name }
        }

        var description: String?
        /// `TableFlowDirectionType` (70): down.
        var flowDirection: Int16 = 0
        var flags: Int16 = 0
        var horizontalCellMargin = 0.06
        var verticalCellMargin = 0.06
        var suppressTitle = false
        var suppressHeaderRow = false
        var dataCellStyle = CellStyle(name: "_DATA")
        var titleCellStyle = CellStyle(name: "_TITLE")
        var headerCellStyle = CellStyle(name: "_HEADER")
        var tableCellStyle = CellStyle(name: "Table")

        override var objectName: String { DxfFileToken.objectTableStyle }
        override var subclassMarker: String { DxfSubclassMarker.tableStyle }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.tableStyle, DxfFileToken.objectTableStyle, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 499, maintenance: 0, proxyFlags: 4095)
        }
    }

    /// Materials are not drawn or written to DXF; they are kept by name for the class counts and the DWG writer.
    final class Material: NonGraphicalObject, DxfClassDefined {
        override var objectName: String { DxfFileToken.objectMaterial }
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
        var isUnnamed = false
        var selectable = true

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
        /// "COLOR$BOOK".
        var colorName: String { name.components(separatedBy: "$").last ?? name }
        var bookName: String { name.contains("$") ? String(name.split(separator: "$", maxSplits: 1)[0]) : "" }

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

        var drawingUnits = 1.0
        var isUnitScale = false
        var paperUnits = 1.0
        var scaleFactor: Double { paperUnits / drawingUnits }

        init(name: String, paper: Double, drawing: Double, isUnit: Bool) {
            paperUnits = paper
            drawingUnits = drawing
            isUnitScale = isUnit
            super.init(name: name)
        }

        override init(name: String = "") { super.init(name: name) }

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
        var sorters: [Sorter] = []

        override var objectName: String { DxfFileToken.objectSortEntsTable }
        override var subclassMarker: String { DxfSubclassMarker.sortentsTable }

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
    final class MultiLeaderObjectContextData: NonGraphicalObject, DxfClassDefined {
        struct StartEndPointPair {
            var startPoint = XYZ.zero
            var endPoint = XYZ.zero
        }

        final class LeaderLine {
            var arrowhead: BlockRecord?
            var arrowheadSize = 0.0
            var breakInfoCount: Int32 = 0
            var breakInfo: [(segmentIndex: Int32, pairs: [StartEndPointPair])] = []
            var index: Int32 = 0
            var lineColor = Color.byBlock
            var lineType: LineType?
            var lineWeight: LineWeight = .byLayer
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
        /// 16 values, row-major (a default `Matrix4` is all zeros).
        var transformationMatrix: [Double] = Array(repeating: 0, count: 16)
        var wordBreak = false
        var scale: Scale?
        var `default` = false
        var version: Int16 = 3

        override var objectName: String { DxfFileToken.objectMLeaderContextData }
        override var subclassMarker: String { DxfSubclassMarker.multiLeaderObjectContextData }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.multiLeaderObjectContextData, DxfFileToken.objectMLeaderContextData, dwgVersion: 0,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }
}
