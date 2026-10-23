// The CAD document (ACadSharp CadDocument): header, classes, symbol tables, the root dictionary and its collections,
// and the handle registry. Objects are registered in the same order as ACadSharp registers them, so objects created
// here (defaults, generated dimension blocks) get the handles ACadSharp would give them.

import Foundation

extension ACad {
    final class Document {
        var header: CadHeader
        let classes = DxfClassCollection()
        var summaryInfo: SummaryInfo?

        private(set) var appIds: AppIdsTable!
        private(set) var blockRecords: BlockRecordsTable!
        private(set) var dimensionStyles: DimensionStylesTable!
        private(set) var layers: LayersTable!
        private(set) var lineTypes: LineTypesTable!
        private(set) var textStyles: TextStylesTable!
        private(set) var ucss: UCSTable!
        private(set) var views: ViewsTable!
        private(set) var vports: VPortsTable!
        /// The DWG viewport entity header control object, kept for the DWG writer.
        var viewportEntityControlHandle: UInt64 = 0

        private(set) var rootDictionary: CadDictionary?
        private(set) var layouts: ObjectCollection<Layout>?
        private(set) var groups: ObjectCollection<Group>?
        private(set) var scales: ObjectCollection<Scale>?
        private(set) var mlineStyles: ObjectCollection<MLineStyle>?
        private(set) var mleaderStyles: ObjectCollection<MultiLeaderStyle>?
        private(set) var tableStyles: ObjectCollection<TableStyle>?
        private(set) var imageDefinitions: ObjectCollection<ImageDefinition>?
        private(set) var pdfDefinitions: ObjectCollection<PdfUnderlayDefinition>?
        private(set) var colors: ObjectCollection<BookColor>?
        private(set) var dictionaryVariables: ObjectCollection<DictionaryVariable>?
        private(set) var materials: ObjectCollection<Material>?

        /// Every registered object by handle (`_cadObjects`), enumerated like a .NET Dictionary.
        private(set) var objects = ObjectRegistry()

        /// `new CadDocument()` creates the default tables, dictionaries and blocks; the readers start empty.
        init(createDefaults: Bool = true) {
            header = CadHeader()
            if createDefaults { self.createDefaults() }
        }

        var modelSpace: BlockRecord { blockRecords[BlockRecord.modelSpaceName]! }
        var paperSpace: BlockRecord? { blockRecords[BlockRecord.paperSpaceName] }
        /// Model space entities.
        var entities: CadObjectCollection<Entity> { modelSpace.entities }

        func object(_ handle: UInt64) -> CadObject? { handle == 0 ? nil : objects[handle] }

        // ───────────────────────── Defaults ─────────────────────────

        /// `CreateDefaults`: missing tables, root dictionary entries, default styles and model / paper space.
        func createDefaults() {
            header.document = self
            summaryInfo = SummaryInfo()
            if blockRecords == nil { registerTable(BlockRecordsTable()) }
            if layers == nil { registerTable(LayersTable()) }
            if dimensionStyles == nil { registerTable(DimensionStylesTable()) }
            if textStyles == nil { registerTable(TextStylesTable()) }
            if lineTypes == nil { registerTable(LineTypesTable()) }
            if views == nil { registerTable(ViewsTable()) }
            if ucss == nil { registerTable(UCSTable()) }
            if vports == nil { registerTable(VPortsTable()) }
            if appIds == nil { registerTable(AppIdsTable()) }

            if let root = rootDictionary {
                CadDictionary.createDefaultEntries(root)
            } else {
                setRootDictionary(CadDictionary.createRoot())
            }
            updateCollections(createDictionaries: true, createDefaults: true)

            appIds.createDefaultEntries()
            lineTypes.createDefaultEntries()
            layers.createDefaultEntries()
            textStyles.createDefaultEntries()
            dimensionStyles.createDefaultEntries()
            vports.createDefaultEntries()

            if !blockRecords.contains(BlockRecord.modelSpaceName) {
                let model = BlockRecord.makeModelSpace()
                if let layout = model.layout { layout.ownedBlock = model; layouts?.add(layout) }
            }
            if !blockRecords.contains(BlockRecord.paperSpaceName) {
                let paper = BlockRecord.makePaperSpace()
                if let layout = paper.layout {
                    layout.tabOrder = 1
                    layout.ownedBlock = paper
                    layouts?.add(layout)
                }
            }
        }

        /// `RegisterCollection` for a symbol table.
        func registerTable(_ table: CadObject) {
            switch table {
            case let t as AppIdsTable: appIds = t
            case let t as BlockRecordsTable: blockRecords = t
            case let t as DimensionStylesTable: dimensionStyles = t
            case let t as LayersTable: layers = t
            case let t as LineTypesTable: lineTypes = t
            case let t as TextStylesTable: textStyles = t
            case let t as UCSTable: ucss = t
            case let t as ViewsTable: views = t
            case let t as VPortsTable: vports = t
            default: break
            }
            table.owner = nil
            addCadObject(table)
        }

        func setRootDictionary(_ root: CadDictionary) {
            rootDictionary = root
            root.owner = nil
            registerCollection(root)
        }

        /// `UpdateCollections`: the typed views of the root dictionary entries, created when missing.
        func updateCollections(createDictionaries: Bool, createDefaults: Bool) {
            if createDictionaries, rootDictionary == nil { setRootDictionary(CadDictionary.createRoot()) }
            guard let root = rootDictionary else { return }

            func collection(_ name: String) -> CadDictionary? {
                if let existing = root.entry(name) as? CadDictionary { return existing }
                guard createDictionaries else { return nil }
                let dictionary = CadDictionary(name: name)
                root.add(dictionary)
                return dictionary
            }

            if let d = collection(CadDictionary.acadLayout) { layouts = ObjectCollection(d) }
            if let d = collection(CadDictionary.acadGroup) { groups = ObjectCollection(d) }
            if let d = collection(CadDictionary.acadScaleList) {
                scales = ObjectCollection(d)
                if createDefaults {
                    for (name, paper, drawing) in [("1:1", 1.0, 1.0), ("1:2", 1, 2), ("1:4", 1, 4), ("1:5", 1, 5), ("1:8", 1, 8),
                                                   ("1:10", 1, 10), ("1:16", 1, 16), ("1:20", 1, 20), ("1:30", 1, 30),
                                                   ("1:40", 1, 40), ("1:50", 1, 50), ("1:100", 1, 100), ("2:1", 2, 1),
                                                   ("4:1", 4, 1), ("8:1", 8, 1), ("10:1", 10, 1), ("100:1", 100, 1)] {
                        d.tryAdd(Scale(name: name, paper: paper, drawing: drawing, isUnit: name == "1:1"))
                    }
                }
            }
            if let d = collection(CadDictionary.acadMLineStyle) {
                mlineStyles = ObjectCollection(d)
                if createDefaults { d.tryAdd(MLineStyle.makeDefault()) }
            }
            if let d = collection(CadDictionary.acadMLeaderStyle) {
                mleaderStyles = ObjectCollection(d)
                if createDefaults { d.tryAdd(MultiLeaderStyle(name: MultiLeaderStyle.defaultName)) }
            }
            if let d = collection(CadDictionary.acadTableStyle) {
                tableStyles = ObjectCollection(d)
                if createDefaults { d.tryAdd(TableStyle(name: TableStyle.defaultName)) }
            }
            if let d = collection(CadDictionary.acadImageDict) { imageDefinitions = ObjectCollection(d) }
            if let d = collection(CadDictionary.acadPdfDefinitions) { pdfDefinitions = ObjectCollection(d) }
            if let d = collection(CadDictionary.acadColor) { colors = ObjectCollection(d) }
            if let d = collection(CadDictionary.variableDictionary) {
                dictionaryVariables = ObjectCollection(d)
                if createDefaults {
                    for (name, value) in [(DictionaryVariable.currentMultiLeaderStyle, MultiLeaderStyle.defaultName),
                                          (DictionaryVariable.currentAnnotationScale, Scale.defaultName),
                                          (DictionaryVariable.currentTableStyle, TableStyle.defaultName),
                                          (DictionaryVariable.wipeoutFrame, "1"),
                                          ("CVIEWDETAILSTYLE", "Metric50"), ("CVIEWSECTIONSTYLE", "Metric50")]
                    where !d.containsKey(name) {
                        d.add(DictionaryVariable(name: name, value: value))
                    }
                }
            }
            if let d = collection(CadDictionary.acadMaterial) {
                materials = ObjectCollection(d)
                if createDefaults {
                    for name in ["Global", "ByLayer", "ByBlock"] { d.tryAdd(Material(name: name)) }
                }
            }
        }

        // ───────────────────────── Registration ─────────────────────────

        /// `AddCadObject`: gives the object a free handle, registers it and lets it resolve its references.
        func addCadObject(_ object: CadObject) {
            if object.document === self, objects[object.handle] === object { return }
            if object.handle == 0 || objects[object.handle] != nil {
                object.handle = header.handleSeed
                header.handleSeed += 1
            } else if object.handle >= header.handleSeed {
                header.handleSeed = object.handle + 1
            }
            objects[object.handle] = object
            object.document = self
            if let record = object as? BlockRecord {
                addCadObject(record.blockEntity)
                addCadObject(record.blockEnd)
            }
            object.assignDocument(self)
        }

        /// `RegisterCollection` for dictionaries: the dictionary and its entries.
        func registerCollection(_ dictionary: CadDictionary) {
            addCadObject(dictionary)
        }

        func unregisterCollection(_ dictionary: CadDictionary) {
            for entry in dictionary.values {
                if let child = entry as? CadDictionary { unregisterCollection(child) } else { removeCadObject(entry) }
            }
            removeCadObject(dictionary)
        }

        /// `RemoveCadObject`.
        func removeCadObject(_ object: CadObject) {
            guard object.handle != 0, objects[object.handle] === object else { return }
            objects.removeValue(forKey: object.handle)
            object.unassignDocument()
        }

        /// Registers an object read from a file under its own handle (the readers' builders).
        func registerRead(_ object: CadObject) {
            addCadObject(object)
        }

        // ───────────────────────── Writer preparation ─────────────────────────

        /// `UpdateDxfClasses`.
        func updateDxfClasses(reset: Bool) {
            if reset { classes.clear() } else { for item in classes { item.instanceCount = 0 } }
            for object in objects.values {
                if let defined = object as? DxfClassDefined { classes.increaseInstanceCount(defined.dxfClass()) }
            }
            classes.resetClassNumbers()
        }

        /// Objects removed from the registry without being detached (the old image reactors): ACadSharp keeps them
        /// as reactors because their `Document` is still set.
        private(set) var retiredHandles = Set<UInt64>()

        /// `UpdateImageReactors`: one IMAGEDEF_REACTOR per image, recreated.
        func updateImageReactors() {
            for reactor in objects.values.compactMap({ $0 as? ImageDefinitionReactor }) {
                objects.removeValue(forKey: reactor.handle)
                retiredHandles.insert(reactor.handle)
            }
            for image in objects.values.compactMap({ $0 as? RasterImage }) {
                guard let definition = image.definition else { continue }
                let reactor = ImageDefinitionReactor()
                reactor.image = image
                reactor.owner = image
                image.definitionReactor = reactor
                addCadObject(reactor)
                definition.addReactor(reactor.handle)
            }
        }
    }

    /// `CadSummaryInfo` (DWG summary information).
    final class SummaryInfo {
        var title = ""
        var subject = ""
        var author = ""
        var keywords = ""
        var comments = ""
        var lastSavedBy = ""
        var revisionNumber = ""
        var hyperlinkBase = ""
        var createdDate = CadDateTime.now()
        var modifiedDate = CadDateTime.now()
        var properties: [(String, String)] = []
    }
}

extension ACad {
    /// `Dictionary<ulong, IHandledCadObject>` with .NET's enumeration order: insertion order, except that a removed
    /// entry's slot is reused by the next insertion (most recently freed first).
    struct ObjectRegistry {
        private var slots: [CadObject?] = []
        private var slotOfHandle: [UInt64: Int] = [:]
        private var freeSlots: [Int] = []

        var count: Int { slotOfHandle.count }

        subscript(handle: UInt64) -> CadObject? {
            get { slotOfHandle[handle].flatMap { slots[$0] } }
            set {
                if let newValue {
                    if let slot = slotOfHandle[handle] {
                        slots[slot] = newValue
                    } else if let slot = freeSlots.popLast() {
                        slots[slot] = newValue
                        slotOfHandle[handle] = slot
                    } else {
                        slotOfHandle[handle] = slots.count
                        slots.append(newValue)
                    }
                } else {
                    removeValue(forKey: handle)
                }
            }
        }

        mutating func removeValue(forKey handle: UInt64) {
            guard let slot = slotOfHandle.removeValue(forKey: handle) else { return }
            slots[slot] = nil
            freeSlots.append(slot)
        }

        /// Values in enumeration order.
        var values: [CadObject] { slots.compactMap { $0 } }
    }
}
