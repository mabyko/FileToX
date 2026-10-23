// The document builders (ACadSharp CadDocumentBuilder and DxfDocumentBuilder): the templates read from a file,
// by handle, and the steps that turn them into a registered document.

import Foundation

extension ACad {
    /// `CadDocumentBuilder`.
    class CadDocumentBuilder {
        let document: Document
        let version: Version
        /// Warnings and errors of the readers (`OnNotification`), for the log.
        var notifications: [String] = []

        var appIds = AppIdsTable()
        var blockRecords = BlockRecordsTable()
        var dimensionStyles = DimensionStylesTable()
        var layers = LayersTable()
        var lineTypes = LineTypesTable()
        var textStyles = TextStylesTable()
        var ucss = UCSTable()
        var views = ViewsTable()
        var vports = VPortsTable()

        var initialHandSeed: UInt64 = 0
        /// ACIS data of R2013+ solids by entity handle (ACDSDATA / DWG data storage).
        var acdsData: [(UInt64, Data)] = []

        private(set) var cadObjects: [UInt64: CadObject] = [:]
        private(set) var templatesMap: [UInt64: CadTemplate] = [:]
        /// Templates in the order they were added (the .NET dictionaries iterate in insertion order).
        private(set) var cadObjectsTemplates: [CadTemplate] = []
        private(set) var dictionaryTemplates: [CadDictionaryTemplate] = []
        private(set) var tableEntryTemplates: [CadTableEntryTemplate] = []
        private(set) var tableTemplates: [UInt64: CadTableTemplateBase] = [:]
        private(set) var unassignedObjects: [CadTemplate] = []

        init(version: Version, document: Document) {
            self.version = version
            self.document = document
        }

        func notify(_ message: String) {
            notifications.append(message)
        }

        /// The first exception a template build would throw; the reader fails with it after building.
        private(set) var failure: String?

        func fail(_ message: String) {
            if failure == nil { failure = message }
        }

        /// `AddTemplate`.
        func addTemplate(_ template: CadTemplate) {
            guard addToMap(template) else { return }
            switch template {
            case let dictionary as CadDictionaryTemplate: dictionaryTemplates.append(dictionary)
            case let table as CadTableTemplateBase: tableTemplates[table.cadObject.handle] = table
            case let entry as CadTableEntryTemplate: tableEntryTemplates.append(entry)
            default: cadObjectsTemplates.append(template)
            }
        }

        private func addToMap(_ template: CadTemplate) -> Bool {
            let handle = template.cadObject.handle
            if handle == 0 {
                unassignedObjects.append(template)
                return false
            }
            if templatesMap[handle] != nil {
                notify("Repeated handle found \(handle).")
                template.cadObject.handle = 0
                unassignedObjects.append(template)
                return false
            }
            if handle > initialHandSeed { initialHandSeed = handle }
            templatesMap[handle] = template
            cadObjects[handle] = template.cadObject
            return true
        }

        /// `createMissingHandles`: objects read without a handle get the next free ones.
        func createMissingHandles() {
            let pending = unassignedObjects
            unassignedObjects.removeAll()
            for template in pending {
                template.cadObject.handle = initialHandSeed + 1
                addTemplate(template)
            }
        }

        /// `TryGetCadObject`.
        func tryGetObject<T: CadObject>(_ handle: UInt64?) -> T? {
            guard let handle, handle != 0, let object = cadObjects[handle] else { return nil }
            if object is UnknownEntity { return nil }
            return object as? T
        }

        func objectTemplate<T: CadTemplate>(_ handle: UInt64?) -> T? {
            guard let handle, handle != 0 else { return nil }
            return templatesMap[handle] as? T
        }

        /// `TryGetTableEntry`: only valid once the tables are built.
        func tableEntry<T: TableEntry>(_ name: String) -> T? {
            guard !name.isEmpty else { return nil }
            switch T.self {
            case is AppId.Type: return appIds[name] as? T
            case is Layer.Type: return layers[name] as? T
            case is LineType.Type: return lineTypes[name] as? T
            case is UCS.Type: return ucss[name] as? T
            case is View.Type: return views[name] as? T
            case is DimensionStyle.Type: return dimensionStyles[name] as? T
            case is TextStyle.Type: return textStyles[name] as? T
            case is BlockRecord.Type: return blockRecords[name] as? T
            default: return nil
            }
        }

        /// `RegisterTables`.
        func registerTables() {
            document.registerTable(appIds)
            document.registerTable(textStyles)
            document.registerTable(lineTypes)
            document.registerTable(layers)
            document.registerTable(ucss)
            document.registerTable(views)
            document.registerTable(blockRecords)
            document.registerTable(dimensionStyles)
            document.registerTable(vports)
        }

        /// `BuildTables`.
        func buildTables() {
            for table in [appIds, textStyles, lineTypes, layers, ucss, views, blockRecords, dimensionStyles, vports] as [CadObject] {
                if let template = tableTemplates[table.handle] {
                    template.build(self)
                } else {
                    notify("Table \(table.objectName) not found in the document")
                }
            }
        }

        /// `buildDictionaries`.
        func buildDictionaries() {
            for template in dictionaryTemplates { template.build(self) }
            if document.rootDictionary == nil {
                let roots = dictionaryTemplates.map { $0.cadObject as! CadDictionary }.filter { $0.owner == nil }
                if roots.count == 1 {
                    document.setRootDictionary(roots[0])
                } else {
                    notify("The root dictionary could not be found.")
                }
            }
            document.updateCollections(createDictionaries: true, createDefaults: false)
        }

        /// `BuildDocument` (base): table entries, then every other object.
        func buildDocument() {
            for template in tableEntryTemplates { template.build(self) }
            for template in cadObjectsTemplates { template.build(self) }
        }
    }

    /// `DxfDocumentBuilder`.
    final class DxfDocumentBuilder: CadDocumentBuilder {
        let createDefaults: Bool
        /// Entities of the ENTITIES section without an owner handle (`ModelSpaceEntities`), in reading order.
        var modelSpaceEntities: [Entity] = []
        var modelSpaceTemplate: CadBlockRecordTemplate?
        var orphanTemplates: [CadTemplate] = []

        init(version: Version, document: Document, createDefaults: Bool) {
            self.createDefaults = createDefaults
            super.init(version: version, document: document)
        }

        override func buildDocument() {
            if modelSpaceTemplate == nil {
                let record = BlockRecord.makeModelSpace()
                blockRecords.add(record)
                let template = CadBlockRecordTemplate(record)
                modelSpaceTemplate = template
                addTemplate(template)
            }
            createMissingHandles()
            var seen = Set<ObjectIdentifier>()
            for entity in modelSpaceEntities where seen.insert(ObjectIdentifier(entity)).inserted {
                modelSpaceTemplate?.ownedObjectsHandlers.insert(entity.handle)
            }
            registerTables()
            buildTables()
            buildDictionaries()
            for template in orphanTemplates { assignOwner(template) }
            super.buildDocument()
            applyAcdsData()
            if createDefaults { document.createDefaults() }
        }

        /// `applyAcdsData`: ACIS payloads read from ACDSDATA replace what the entity carried.
        private func applyAcdsData() {
            for (handle, data) in acdsData {
                if let geometry: ModelerGeometry = tryGetObject(handle) {
                    geometry.acisData = data
                } else {
                    notify("ACDSDATA record owner \(handle) is not a ModelerGeometry entity in the document")
                }
            }
        }

        private func assignOwner(_ template: CadTemplate) {
            guard template.cadObject.owner == nil, !(template.cadObject is CadDictionary), let ownerHandle = template.ownerHandle else { return }
            guard let owner: CadTemplate = objectTemplate(ownerHandle) else {
                notify("Owner \(ownerHandle) not found for \(type(of: template)) with handle \(template.cadObject.handle)")
                return
            }
            switch (owner, template.cadObject) {
            case (is CadDictionaryTemplate, _): break
            case (is CadBlockRecordTemplate, is Entity): break
            case let (pline as CadPolyLineTemplate, vertex as Vertex): pline.ownedObjectsHandlers.insert(vertex.handle)
            case let (pline as CadPolyLineTemplate, seqend as Seqend): pline.seqendHandle = seqend.handle
            case let (insert as CadInsertTemplate, attribute as AttributeEntity): insert.ownedObjectsHandlers.insert(attribute.handle)
            case let (insert as CadInsertTemplate, seqend as Seqend): insert.seqendHandle = seqend.handle
            default:
                notify("Owner \(type(of: owner)) with handle \(ownerHandle) assignation not implemented for \(template.cadObject.objectName) with handle \(template.cadObject.handle)")
            }
        }
    }

    /// `AcisTextCodec`: the character swap of pre-2013 SAT text.
    enum AcisTextCodec {
        static func decode(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.map { c in
                c.value > 0x20 && c.value < 0x9F ? Unicode.Scalar(0x9F - c.value)! : c
            }))
        }

        static func isEncoded(_ text: String) -> Bool {
            for c in text.unicodeScalars where c.value > 0x20 {
                return !CharacterSet.decimalDigits.contains(c)
            }
            return false
        }
    }
}
