// Base classes of the CAD document model (ACadSharp CadObject, Entity, NonGraphicalObject, TableEntry, Table,
// CadObjectCollection, SeqendCollection and extended data). Owners and the document are weak references and
// reactors are kept as handles, so a drawing's object graph has no reference cycles and is freed after a conversion.

import Foundation

extension ACad {
    /// DWG object type numbers (`ObjectType`).
    enum ObjectType: Int16 {
        case unlisted = -999, invalid = -1, undefined = 0
        case text = 1, attrib = 2, attdef = 3, block = 4, endblk = 5, seqend = 6, insert = 7, minsert = 8, unknow9 = 9
        case vertex2D = 0x0A, vertex3D = 0x0B, vertexMesh = 0x0C, vertexPface = 0x0D, vertexPfaceFace = 0x0E
        case polyline2D = 0x0F, polyline3D = 0x10, arc = 0x11, circle = 0x12, line = 0x13
        case dimensionOrdinate = 0x14, dimensionLinear = 0x15, dimensionAligned = 0x16, dimensionAng3Pt = 0x17
        case dimensionAng2Ln = 0x18, dimensionRadius = 0x19, dimensionDiameter = 0x1A
        case point = 0x1B, face3D = 0x1C, polylinePface = 0x1D, polylineMesh = 0x1E, solid = 0x1F, trace = 0x20
        case shape = 0x21, viewport = 0x22, ellipse = 0x23, spline = 0x24, region = 0x25, solid3D = 0x26, body = 0x27
        case ray = 0x28, xline = 0x29, dictionary = 0x2A, oleframe = 0x2B, mtext = 0x2C, leader = 0x2D
        case tolerance = 0x2E, mline = 0x2F
        case blockControlObj = 0x30, blockHeader = 0x31, layerControlObj = 0x32, layer = 0x33
        case styleControlObj = 0x34, style = 0x35, unknow36 = 0x36, unknow37 = 0x37
        case ltypeControlObj = 0x38, ltype = 0x39, unknow3A = 0x3A, unknow3B = 0x3B
        case viewControlObj = 0x3C, view = 0x3D, ucsControlObj = 0x3E, ucs = 0x3F, vportControlObj = 0x40, vport = 0x41
        case appidControlObj = 0x42, appid = 0x43, dimstyleControlObj = 0x44, dimstyle = 0x45
        case vpEntHdrCtrlObj = 0x46, vpEntHdr = 0x47, group = 0x48, mlinestyle = 0x49, ole2frame = 0x4A, dummy = 0x4B
        case longTransaction = 0x4C, lwpolyline = 0x4D, hatch = 0x4E, xrecord = 0x4F, acdbplaceholder = 0x50
        case vbaProject = 0x51, layout = 0x52, acadProxyEntity = 0x1F2, acadProxyObject = 0x1F3
    }

    // ───────────────────────── Extended data ─────────────────────────

    /// One extended data value (`ExtendedDataRecord` and its subclasses). The code is the DXF group code.
    enum XDataRecord {
        case string(String) // 1000
        case controlString(isClosing: Bool) // 1002
        case layer(UInt64) // 1003 (a layer handle)
        case binaryChunk(Data) // 1004
        case handle(UInt64) // 1005
        case coordinate(XYZ) // 1010
        case worldCoordinate(XYZ) // 1011
        case displacement(XYZ) // 1012
        case direction(XYZ) // 1013
        case real(Double) // 1040
        case distance(Double) // 1041
        case scale(Double) // 1042
        case integer16(Int16) // 1070
        case integer32(Int32) // 1071

        var code: Int {
            switch self {
            case .string: return 1000
            case .controlString: return 1002
            case .layer: return 1003
            case .binaryChunk: return 1004
            case .handle: return 1005
            case .coordinate: return 1010
            case .worldCoordinate: return 1011
            case .displacement: return 1012
            case .direction: return 1013
            case .real: return 1040
            case .distance: return 1041
            case .scale: return 1042
            case .integer16: return 1070
            case .integer32: return 1071
            }
        }
    }

    /// The records one application attached to an object (`ExtendedData`).
    final class ExtendedData {
        var records: [XDataRecord] = []
        init(_ records: [XDataRecord] = []) { self.records = records }
    }

    /// Extended data of an object by application (`ExtendedDataDictionary`), in insertion order.
    final class ExtendedDataDictionary {
        private(set) var entries: [(app: AppId, data: ExtendedData)] = []
        unowned let owner: CadObject

        init(owner: CadObject) { self.owner = owner }

        var isEmpty: Bool { entries.isEmpty }

        /// `Add(AppId, ExtendedData)`: an application already in the document's table is reused, a new one is added.
        func add(_ app: AppId, _ data: ExtendedData) {
            if let document = owner.document {
                if let existing = document.appIds[app.name] {
                    entries.append((existing, data))
                } else {
                    document.appIds.add(app)
                    entries.append((app, data))
                }
            } else {
                entries.append((app, data))
            }
        }

        func get(_ name: String) -> ExtendedData? {
            entries.first { $0.app.name.caseInsensitiveCompare(name) == .orderedSame }?.data
        }

        func removeAll() { entries.removeAll() }

        /// Re-resolves the applications against a document (`AssignDocument`).
        func reassign(to document: Document) {
            let old = entries
            entries.removeAll()
            for (app, data) in old { add(app, data) }
        }
    }

    // ───────────────────────── Objects ─────────────────────────

    /// `CadObject`: anything with a handle.
    class CadObject {
        var handle: UInt64 = 0
        /// The owning object; nil for objects owned by the document (tables, root dictionary) or not attached.
        weak var owner: CadObject?
        /// Handles of the objects notified about changes (`Reactors`).
        var reactors: [UInt64] = []
        private(set) var xDictionary: CadDictionary?
        private var _extendedData: ExtendedDataDictionary?
        weak var document: Document?

        init() {}

        var objectName: String { "" }
        var subclassMarker: String { "" }
        var objectType: ObjectType { .unlisted }

        /// Created on first use: most objects have no extended data.
        var extendedData: ExtendedDataDictionary {
            if let data = _extendedData { return data }
            let data = ExtendedDataDictionary(owner: self)
            _extendedData = data
            return data
        }

        var hasExtendedData: Bool { !(_extendedData?.isEmpty ?? true) }

        /// The owner's handle as written to files (0 for the document).
        var ownerHandle: UInt64 { owner?.handle ?? 0 }

        func setXDictionary(_ dictionary: CadDictionary?) {
            guard let dictionary else { return }
            xDictionary = dictionary
            dictionary.owner = self
            document?.registerCollection(dictionary)
        }

        /// `CreateExtendedDictionary`.
        func createExtendedDictionary() -> CadDictionary {
            if let xDictionary { return xDictionary }
            let dictionary = CadDictionary()
            setXDictionary(dictionary)
            return dictionary
        }

        func addReactor(_ handle: UInt64) { reactors.append(handle) }

        /// `IsValid` for the writers: orientable objects need a non-zero normal.
        func isValid() -> Bool {
            if let orientable = self as? Orientable, orientable.normal.isZero { return false }
            return true
        }

        /// `AssignDocument`: called once the object is registered in `document`.
        func assignDocument(_ document: Document) {
            self.document = document
            if let xDictionary { document.registerCollection(xDictionary) }
            if hasExtendedData { extendedData.reassign(to: document) }
        }

        func unassignDocument() {
            if let xDictionary { document?.unregisterCollection(xDictionary) }
            handle = 0
            document = nil
            reactors.removeAll()
        }

        var debugName: String { "\(objectName):\(String(handle, radix: 16, uppercase: true))" }
    }

    /// Entities and objects with an extrusion direction (`IOrientable`).
    protocol Orientable: AnyObject {
        var normal: XYZ { get set }
    }

    /// `NonGraphicalObject`: dictionary entries such as layouts and styles.
    class NonGraphicalObject: CadObject {
        /// Name of the dictionary entry that holds the object.
        var name: String = "" {
            didSet { (owner as? CadDictionary)?.entryRenamed(self, from: oldValue) }
        }

        init(name: String = "") {
            self.name = name
            super.init()
        }
    }

    /// `Entity`: common properties of everything drawn.
    class Entity: CadObject {
        private var _layer: Layer?
        private var _lineType: LineType?
        /// Layer "0" (a detached one until the entity joins a document) unless set.
        var layer: Layer {
            get {
                if let layer = _layer { return layer }
                let layer = Layer.makeDefault()
                _layer = layer
                return layer
            }
            set { _layer = newValue }
        }
        /// ByLayer unless set.
        var lineType: LineType {
            get {
                if let lineType = _lineType { return lineType }
                let lineType = LineType.makeByLayer()
                _lineType = lineType
                return lineType
            }
            set { _lineType = newValue }
        }
        var color: Color = .byLayer
        var lineWeight: LineWeight = .byLayer
        var lineTypeScale = 1.0
        var isInvisible = false
        var transparency: Transparency = .byLayer
        var material: NonGraphicalObject?
        var bookColor: BookColor?

        override var subclassMarker: String { DxfSubclassMarker.entity }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            _layer = _layer.map { document.layers.resolve($0) } ?? document.layers[Layer.defaultName] ?? document.layers.tryAdd(Layer.makeDefault())
            _lineType = _lineType.map { document.lineTypes.resolve($0) } ?? document.lineTypes[LineType.byLayerName] ?? document.lineTypes.tryAdd(LineType.makeByLayer())
            if let bookColor {
                self.bookColor = document.colors?.resolve(bookColor) ?? bookColor
            }
        }

        /// `MatchProperties` (used by generated dimension blocks).
        func matchProperties(_ other: Entity) {
            layer = other.layer
            lineType = other.lineType
            material = other.material
            color = other.color
            lineWeight = other.lineWeight
            lineTypeScale = other.lineTypeScale
            isInvisible = other.isInvisible
            transparency = other.transparency
        }
    }

    /// `TableEntry`: a named record of a symbol table.
    class TableEntry: CadObject {
        var name: String {
            didSet { (owner as? TableEntryRenaming)?.entryRenamed(self, from: oldValue) }
        }
        /// `StandardFlags` (70).
        var flags: Int16 = 0

        required init(name: String) {
            self.name = name
            super.init()
        }

        override var subclassMarker: String { DxfSubclassMarker.tableRecord }
    }

    /// `Table<T>`: a symbol table keyed by name (`OrdinalIgnoreCase`), in .NET dictionary order.
    /// Collections keyed by their entries' names (`OnNameChanged` subscribers).
    protocol TableEntryRenaming: AnyObject {
        func entryRenamed(_ entry: TableEntry, from oldName: String)
    }

    class Table<T: TableEntry>: CadObject, Sequence, TableEntryRenaming {
        private var map = NameMap<T>()

        override var objectName: String { DxfFileToken.tableEntry }
        override var subclassMarker: String { DxfSubclassMarker.table }

        /// Names created by `CreateDefaultEntries`.
        var defaultEntries: [String] { [] }
        func defaultEntry() -> T? { nil }

        var entries: [T] { map.values }
        var count: Int { map.count }
        func makeIterator() -> IndexingIterator<[T]> { map.values.makeIterator() }

        subscript(name: String) -> T? { map[name] }

        func contains(_ name: String) -> Bool { map.containsKey(name) }

        /// `Add`; false where ACadSharp throws for a duplicate name. Anonymous blocks and duplicate viewports are
        /// handled by the subclasses.
        @discardableResult
        func add(_ item: T) -> Bool {
            if item.name.isEmpty { item.name = createName("unnamed") }
            return insert(item, key: item.name)
        }

        /// `add(key, item)` / `addHandlePrefix`.
        @discardableResult
        func insert(_ item: T, key: String) -> Bool {
            guard map.add(key, item) else { return false }
            item.owner = self
            document?.addCadObject(item)
            return true
        }

        /// `TryAdd`: the existing entry with the item's name, or the item after adding it.
        @discardableResult
        func tryAdd(_ item: T) -> T {
            if let existing = self[item.name] { return existing }
            add(item)
            return item
        }

        /// `UpdateReference`: entries assigned to an object belong to this table (same name → the existing one).
        func resolve(_ entry: T) -> T {
            if entry.document === document, self[entry.name] === entry { return entry }
            return tryAdd(entry)
        }

        /// `Remove`: default entries stay (the names are compared with case, like `string[].Contains`).
        @discardableResult
        func remove(_ name: String) -> T? {
            if defaultEntries.contains(name) { return nil }
            guard let item = map.remove(name) else { return nil }
            item.owner = nil
            document?.removeCadObject(item)
            return item
        }

        /// `onEntryNameChanged`: the entry is added under its new name, then the old key is removed.
        func entryRenamed(_ entry: TableEntry, from oldName: String) {
            guard let entry = entry as? T,
                  !defaultEntries.contains(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }),
                  map[oldName] === entry, map.add(entry.name, entry) else { return }
            map.remove(oldName)
        }

        func createName(_ prefix: String) -> String {
            var i = 0
            while map.containsKey("\(prefix)\(i)") { i += 1 }
            return "\(prefix)\(i)"
        }

        /// `CreateDefaultEntries`.
        func createDefaultEntries() {
            for name in defaultEntries where !contains(name) {
                add(T(name: name))
            }
        }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            for entry in entries { document.addCadObject(entry) }
        }
    }

    /// `CadObjectCollection<T>`: objects owned by another object (block entities, mesh faces), in insertion order.
    class CadObjectCollection<T: CadObject>: Sequence {
        private(set) var entries: [T] = []
        private var members = Set<ObjectIdentifier>()
        unowned let owner: CadObject
        /// Lets an owner veto removals (`OnBeforeRemove`).
        var canRemove: ((T) -> Bool)?

        init(owner: CadObject) { self.owner = owner }

        var count: Int { entries.count }
        var isEmpty: Bool { entries.isEmpty }
        var first: T? { entries.first }
        subscript(i: Int) -> T { entries[i] }
        func makeIterator() -> IndexingIterator<[T]> { entries.makeIterator() }

        func add(_ item: T) {
            guard item.owner == nil, members.insert(ObjectIdentifier(item)).inserted else { return }
            entries.append(item)
            item.owner = owner
            owner.document?.addCadObject(item)
            didAdd(item)
        }

        func didAdd(_ item: T) {}

        @discardableResult
        func remove(_ item: T) -> Bool {
            if let canRemove, !canRemove(item) { return false }
            guard members.remove(ObjectIdentifier(item)) != nil else { return false }
            entries.removeAll { $0 === item }
            item.owner = nil
            owner.document?.removeCadObject(item)
            didRemove()
            return true
        }

        /// Removes every matching item at once (keeps large removals linear).
        func removeAll(where predicate: (T) -> Bool) -> Int {
            let removed = entries.filter { predicate($0) && (canRemove?($0) ?? true) }
            guard !removed.isEmpty else { return 0 }
            let ids = Set(removed.map(ObjectIdentifier.init))
            entries.removeAll { ids.contains(ObjectIdentifier($0)) }
            members.subtract(ids)
            for item in removed {
                item.owner = nil
                owner.document?.removeCadObject(item)
            }
            didRemove()
            return removed.count
        }

        func didRemove() {}

        func registerAll(in document: Document) {
            for item in entries { document.addCadObject(item) }
        }
    }

    /// `SeqendCollection<T>`: vertices and attributes followed by a SEQEND marker while not empty.
    final class SeqendCollection<T: CadObject>: CadObjectCollection<T> {
        private var _seqend: Seqend

        override init(owner: CadObject) {
            _seqend = Seqend()
            super.init(owner: owner)
            _seqend.owner = owner
        }

        var seqend: Seqend? {
            get { isEmpty ? nil : _seqend }
            set {
                guard let newValue else { return }
                _seqend = newValue
                newValue.owner = owner
            }
        }

        override func didAdd(_ item: T) {
            if count == 1 { owner.document?.addCadObject(_seqend) }
        }

        override func didRemove() {
            if isEmpty { owner.document?.removeCadObject(_seqend) }
        }

        override func registerAll(in document: Document) {
            super.registerAll(in: document)
            if !isEmpty { document.addCadObject(_seqend) }
        }
    }
}
