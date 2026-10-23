// Reader templates (ACadSharp IO/Templates): what an object refers to by handle or name while a file is read, and
// how those references are resolved once every object exists. Shared by the DXF and DWG readers.

import Foundation

extension ACad {
    /// An insertion-ordered set of handles (.NET `HashSet<ulong>` without removals).
    struct HandleSet: Sequence {
        private(set) var items: [UInt64] = []
        private var members = Set<UInt64>()

        mutating func insert(_ handle: UInt64) {
            if members.insert(handle).inserted { items.append(handle) }
        }

        mutating func formUnion<S: Sequence>(_ other: S) where S.Element == UInt64 {
            for handle in other { insert(handle) }
        }

        var isEmpty: Bool { items.isEmpty }
        var count: Int { items.count }
        func makeIterator() -> IndexingIterator<[UInt64]> { items.makeIterator() }
    }

    /// `CadTemplate`.
    class CadTemplate {
        var cadObject: CadObject
        var ownerHandle: UInt64?
        var xdictHandle: UInt64?
        var reactorsHandles = HandleSet()
        /// Extended data by application handle (DWG) and by application name (DXF), in reading order.
        var edataByHandle: [(UInt64, [XDataRecord])] = []
        var edataByAppName: [(String, [XDataRecord])] = []
        var dxfClass: DxfClass?
        private(set) var hasBeenBuilt = false

        init(_ object: CadObject) { cadObject = object }

        final func build(_ builder: CadDocumentBuilder) {
            guard !hasBeenBuilt else { return }
            hasBeenBuilt = true
            buildCore(builder)
        }

        func buildCore(_ builder: CadDocumentBuilder) {
            if let dictionary: CadDictionary = builder.tryGetObject(xdictHandle) {
                cadObject.setXDictionary(dictionary)
            }
            for handle in reactorsHandles {
                if builder.tryGetObject(handle) as CadObject? != nil {
                    cadObject.addReactor(handle)
                } else {
                    builder.notify("Reactor with handle \(handle) not found")
                }
            }
            for (handle, records) in edataByHandle {
                if let app: AppId = builder.tryGetObject(handle) {
                    cadObject.extendedData.add(app, ExtendedData(records))
                } else {
                    builder.notify("AppId in extended data with handle \(handle) not found")
                }
            }
            for (name, records) in edataByAppName {
                if let app = builder.appIds[name] {
                    cadObject.extendedData.add(app, ExtendedData(records))
                } else {
                    builder.notify("AppId in extended data with handle \(name) not found")
                }
            }
        }

        /// `getTableReference`: by handle, else by name.
        func tableReference<T: TableEntry>(_ builder: CadDocumentBuilder, _ handle: UInt64?, _ name: String?) -> T? {
            if let object: T = builder.tryGetObject(handle) { return object }
            if let name, let entry: T = builder.tableEntry(name) { return entry }
            if (name.map { !$0.isEmpty } ?? false) || (handle ?? 0) != 0 {
                builder.notify("\(T.self) table reference with handle: \(handle.map(String.init) ?? "") | name: \(name ?? "") not found for \(cadObject.objectName) with handle \(cadObject.handle)")
            }
            return nil
        }

        /// `getEntitiesCollection`: a DWG entity chain from `first` to `end` (next-entity links, else handle + 1). The C#
        /// casts of the templates and objects throw on a mismatch, which fails the reading (`builder.fail`).
        func entitiesCollection<T: Entity>(_ builder: CadDocumentBuilder, first: UInt64, end: UInt64, as _: T.Type = Entity.self) -> [T] {
            var result: [T] = []
            func entityTemplate(_ handle: UInt64) -> CadEntityTemplate? {
                guard let found: CadTemplate = builder.objectTemplate(handle) else { return nil }
                guard let template = found as? CadEntityTemplate else {
                    builder.fail("Unable to cast object of type 'ACadSharp.IO.Templates.\(type(of: found))' to type 'ACadSharp.IO.Templates.CadEntityTemplate'.")
                    return nil
                }
                return template
            }
            var template = entityTemplate(first)
            if template == nil {
                builder.notify("Leading entity with handle \(first) not found.")
                template = entityTemplate(end)
            }
            var guardCount = 0
            while let t = template {
                guard let entity = t.cadObject as? T else {
                    builder.fail("Unable to cast object of type 'ACadSharp.Entities.\(type(of: t.cadObject))' to type 'ACadSharp.Entities.\(T.self)'.")
                    break
                }
                result.append(entity)
                guardCount += 1
                if t.cadObject.handle == end || guardCount > 10_000_000 { break }
                template = entityTemplate(t.nextEntity ?? t.cadObject.handle + 1)
            }
            return result
        }
    }

    /// Templates of objects that own other objects (blocks, inserts, polylines).
    protocol CadOwnerTemplate: AnyObject {
        var ownedObjectsHandlers: HandleSet { get set }
    }

    // ───────────────────────── Entities ─────────────────────────

    class CadEntityTemplate: CadTemplate {
        var bookColorName: String?
        var colorHandle: UInt64?
        var entityMode: UInt8 = 0
        var layerHandle: UInt64?
        var layerName: String?
        var lineTypeHandle: UInt64?
        var lineTypeName: String?
        var ltypeFlags: UInt8?
        var materialHandle: UInt64?
        var nextEntity: UInt64?
        var prevEntity: UInt64?

        var entity: Entity { cadObject as! Entity }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let entity = self.entity
            if let layer: Layer = tableReference(builder, layerHandle, layerName) {
                entity.layer = layer
            } else if let layerName, !layerName.isEmpty {
                builder.notify("Layer \(layerName) not found in the LAYER table, created for \(entity.objectName) with handle \(entity.handle)")
                entity.layer = builder.layers.tryAdd(Layer(name: layerName))
            }
            switch ltypeFlags {
            case 0: lineTypeName = LineType.byLayerName
            case 1: lineTypeName = LineType.byBlockName
            case 2: lineTypeName = LineType.continuousName
            default: break
            }
            if let lineType: LineType = tableReference(builder, lineTypeHandle, lineTypeName) {
                entity.lineType = lineType
            }
            if let color: BookColor = builder.tryGetObject(colorHandle) {
                entity.bookColor = color
            } else if let bookColorName, !bookColorName.isEmpty, let color = builder.document.colors?[bookColorName] {
                entity.bookColor = color
            }
            if let material: Material = builder.tryGetObject(materialHandle) {
                entity.material = material
            }
        }
    }

    final class CadBlockEntityTemplate: CadEntityTemplate, CadOwnerTemplate {
        var ownedObjectsHandlers = HandleSet()
    }

    final class CadTextEntityTemplate: CadEntityTemplate {
        var styleHandle: UInt64?
        var styleName: String?
        /// The embedded MTEXT of a multi-line attribute (DXF 101 / DWG R2018).
        var mtextTemplate: CadTextEntityTemplate?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let style: TextStyle = tableReference(builder, styleHandle, styleName) {
                switch cadObject {
                case let text as TextEntity: text.style = style
                case let mtext as MText: mtext.style = style
                default: break
                }
            }
            mtextTemplate?.build(builder)
        }
    }

    class CadInsertTemplate: CadEntityTemplate, CadOwnerTemplate {
        var hasAtts = false
        var ownedObjectsCount = 0
        var blockHeaderHandle: UInt64?
        var blockName: String?
        var firstAttributeHandle: UInt64?
        var endAttributeHandle: UInt64?
        var seqendHandle: UInt64?
        var ownedObjectsHandlers = HandleSet()

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            guard let insert = cadObject as? Insert else { return }
            if let block: BlockRecord = tableReference(builder, blockHeaderHandle, blockName) {
                insert.block = block
            } else {
                builder.notify("Block \(blockHeaderHandle.map(String.init) ?? "") | \(blockName ?? "") not found for Insert \(insert.handle)")
            }
            if let seqend: Seqend = builder.tryGetObject(seqendHandle) {
                insert.attributes.seqend = seqend
            }
            if let first = firstAttributeHandle {
                for attribute in entitiesCollection(builder, first: first, end: endAttributeHandle ?? first, as: AttributeEntity.self) {
                    insert.attributes.add(attribute)
                }
            } else {
                for handle in ownedObjectsHandlers {
                    if let attribute: AttributeEntity = builder.tryGetObject(handle) { insert.attributes.add(attribute) }
                }
            }
        }
    }

    final class CadPolyLineTemplate: CadEntityTemplate, CadOwnerTemplate {
        var firstVertexHandle: UInt64?
        var lastVertexHandle: UInt64?
        var seqendHandle: UInt64?
        var ownedObjectsHandlers = HandleSet()
        /// True until the DXF subclass marker says which polyline this is (`PolyLinePlaceholder`).
        var isPlaceholder = false

        /// `SetPolyLineObject`.
        func setPolyline(_ polyline: Polyline) {
            let source = entity
            polyline.handle = source.handle
            polyline.color = source.color
            polyline.lineWeight = source.lineWeight
            polyline.lineTypeScale = source.lineTypeScale
            polyline.isInvisible = source.isInvisible
            polyline.transparency = source.transparency
            if let old = source as? Polyline {
                polyline.flags = old.flags
                polyline.elevation = old.elevation
                polyline.thickness = old.thickness
                polyline.normal = old.normal
                polyline.startWidth = old.startWidth
                polyline.endWidth = old.endWidth
                polyline.smoothSurface = old.smoothSurface
            }
            cadObject = polyline
            isPlaceholder = false
        }

        private func addVertex(_ builder: CadDocumentBuilder, _ vertex: Entity) {
            switch cadObject {
            case let mesh as PolyfaceMesh: addPolyfaceMeshVertex(builder, mesh, vertex)
            case let polyline as Polyline:
                if let v = vertex as? Vertex { polyline.vertices.add(v) }
            default:
                builder.notify("Unknown polyline type \(cadObject.subclassMarker)")
            }
        }

        private func setSeqend(_ seqend: Seqend) {
            (cadObject as? Polyline)?.vertices.seqend = seqend
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let seqend: Seqend = builder.tryGetObject(seqendHandle) { setSeqend(seqend) }
            if let first = firstVertexHandle {
                for vertex in entitiesCollection(builder, first: first, end: lastVertexHandle ?? first, as: Vertex.self) { addVertex(builder, vertex) }
            } else if let mesh = cadObject as? PolyfaceMesh {
                for handle in ownedObjectsHandlers {
                    if let e: Entity = builder.tryGetObject(handle) { addPolyfaceMeshVertex(builder, mesh, e) }
                }
            } else {
                for handle in ownedObjectsHandlers {
                    if let vertex: Vertex = builder.tryGetObject(handle) {
                        addVertex(builder, vertex)
                    } else if let seqend: Seqend = builder.tryGetObject(handle) {
                        setSeqend(seqend)
                    } else {
                        builder.notify("Vertex \(handle) not found for polyline \(cadObject.handle)")
                    }
                }
            }
        }

        private func addPolyfaceMeshVertex(_ builder: CadDocumentBuilder, _ mesh: PolyfaceMesh, _ e: Entity) {
            if let vertex = e as? VertexFaceMesh {
                mesh.vertices.add(vertex)
            } else if let face = e as? VertexFaceRecord {
                mesh.faces.add(face)
            } else if let seqend = e as? Seqend {
                mesh.vertices.seqend = seqend
            } else {
                builder.notify("Unidentified type for PolyfaceMesh \(e.objectName)")
            }
        }
    }

    final class CadVertexTemplate: CadEntityTemplate {
        var isPlaceholder = false

        /// `SetVertexObject`.
        func setVertex(_ vertex: Vertex) {
            let placeholder = cadObject as! Vertex
            vertex.handle = placeholder.handle
            vertex.owner = placeholder.owner
            vertex.color = placeholder.color
            vertex.lineWeight = placeholder.lineWeight
            vertex.lineTypeScale = placeholder.lineTypeScale
            vertex.isInvisible = placeholder.isInvisible
            vertex.transparency = placeholder.transparency
            vertex.location = placeholder.location
            vertex.startWidth = placeholder.startWidth
            vertex.endWidth = placeholder.endWidth
            vertex.bulge = placeholder.bulge
            vertex.flags = placeholder.flags
            vertex.curveTangent = placeholder.curveTangent
            vertex.id = placeholder.id
            cadObject = vertex
            isPlaceholder = false
        }
    }

    final class CadDimensionTemplate: CadEntityTemplate {
        var styleHandle: UInt64?
        var blockHandle: UInt64?
        var blockName: String?
        var styleName: String?
        /// The dimension type is not known yet (`DimensionPlaceholder`).
        var isPlaceholder = false

        var dimension: Dimension { cadObject as! Dimension }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let style: DimensionStyle = tableReference(builder, styleHandle, styleName) { dimension.style = style }
            if let block: BlockRecord = tableReference(builder, blockHandle, blockName) { dimension.block = block }
        }

        /// `SetDimensionObject`.
        func setDimension(_ new: Dimension) {
            guard type(of: cadObject) != type(of: new) || isPlaceholder else { return }
            let source = dimension
            new.handle = source.handle
            new.owner = source.owner
            new.color = source.color
            new.lineWeight = source.lineWeight
            new.lineTypeScale = source.lineTypeScale
            new.isInvisible = source.isInvisible
            new.transparency = source.transparency
            new.version = source.version
            new.definitionPoint = source.definitionPoint
            new.textMiddlePoint = source.textMiddlePoint
            new.insertionPoint = source.insertionPoint
            new.normal = source.normal
            new.isTextUserDefinedLocation = source.isTextUserDefinedLocation
            new.attachmentPoint = source.attachmentPoint
            new.lineSpacingStyle = source.lineSpacingStyle
            new.lineSpacingFactor = source.lineSpacingFactor
            new.text = source.text
            new.textRotation = source.textRotation
            new.horizontalDirection = source.horizontalDirection
            new.flags = source.flags
            if !isPlaceholder, let aligned = source as? DimensionAligned, let linear = new as? DimensionLinear {
                linear.firstPoint = aligned.firstPoint
                linear.secondPoint = aligned.secondPoint
                linear.extLineRotation = aligned.extLineRotation
            }
            cadObject = new
            isPlaceholder = false
        }
    }

    final class CadHatchTemplate: CadEntityTemplate {
        final class BoundaryPathTemplate {
            let path = Hatch.BoundaryPath()
            var handles = HandleSet()

            func build(_ builder: CadDocumentBuilder) {
                for handle in handles {
                    if let entity: Entity = builder.tryGetObject(handle) { path.entities.append(entity) }
                }
            }
        }

        var hatchPatternName: String?
        var pathTemplates: [BoundaryPathTemplate] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let hatch = cadObject as! Hatch
            for template in pathTemplates {
                hatch.paths.append(template.path)
                template.build(builder)
            }
        }
    }

    final class CadLeaderTemplate: CadEntityTemplate {
        var dimasz = 0.0
        var dimStyleHandle: UInt64 = 0
        var dimStyleName: String?
        var annotationHandle: UInt64 = 0

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let leader = cadObject as! Leader
            if let style: DimensionStyle = tableReference(builder, dimStyleHandle, dimStyleName) { leader.style = style }
            if let annotation: Entity = builder.tryGetObject(annotationHandle) { leader.associatedAnnotation = annotation }
        }
    }

    final class CadMLineTemplate: CadEntityTemplate {
        var mlineStyleHandle: UInt64?
        var mlineStyleName: String?
        var nVertex: Int32?
        var nElements: Int32?
        private var currentVertex: MLine.Vertex?
        private var currentSegment: MLine.Vertex.Segment?

        /// `TryReadVertex`.
        func tryReadVertex(_ code: Int, _ value: Double) -> Bool {
            let mline = cadObject as! MLine
            switch code {
            case 11:
                let vertex = MLine.Vertex()
                currentVertex = vertex
                mline.vertices.append(vertex)
                vertex.position.x = value
            case 21: currentVertex?.position.y = value
            case 31: currentVertex?.position.z = value
            case 12: currentVertex?.direction.x = value
            case 22: currentVertex?.direction.y = value
            case 32: currentVertex?.direction.z = value
            case 13: currentVertex?.miter.x = value
            case 23: currentVertex?.miter.y = value
            case 33: currentVertex?.miter.z = value
            case 41: currentSegment?.parameters.append(value)
            case 42: currentSegment?.areaFillParameters.append(value)
            default: return false
            }
            return true
        }

        func newSegment() {
            let segment = MLine.Vertex.Segment()
            currentSegment = segment
            currentVertex?.segments.append(segment)
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let style: MLineStyle = builder.tryGetObject(mlineStyleHandle) { (cadObject as! MLine).style = style }
        }
    }

    final class CadMLeaderTemplate: CadEntityTemplate {
        final class LeaderLineTemplate {
            let leaderLine: MultiLeaderObjectContextData.LeaderLine
            var arrowSymbolHandle: UInt64?
            var lineTypeHandle: UInt64?
            init(_ line: MultiLeaderObjectContextData.LeaderLine = .init()) { leaderLine = line }

            func build(_ builder: CadDocumentBuilder) {
                if let lineType: LineType = builder.tryGetObject(lineTypeHandle) { leaderLine.lineType = lineType }
                if let arrow: BlockRecord = builder.tryGetObject(arrowSymbolHandle) { leaderLine.arrowhead = arrow }
            }
        }

        var arrowheadHandle: UInt64 = 0
        var blockContentHandle: UInt64 = 0
        var leaderLineTypeHandle: UInt64?
        var leaderStyleHandle: UInt64 = 0
        var mtextStyleHandle: UInt64 = 0
        var contextTextStyleHandle: UInt64 = 0
        var contextBlockRecordHandle: UInt64 = 0
        var contextScaleHandle: UInt64?
        var leaderLineTemplates: [LeaderLineTemplate] = []
        var blockAttributeHandles: [UInt64] = []
        var arrowheadHandles: [(UInt64, Bool)] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let leader = cadObject as! MultiLeader
            let context = leader.contextData
            if let scale: Scale = builder.tryGetObject(contextScaleHandle) { context.scale = scale }
            if let style: TextStyle = builder.tryGetObject(contextTextStyleHandle) { context.textStyle = style }
            if let block: BlockRecord = builder.tryGetObject(contextBlockRecordHandle) { context.blockContent = block }
            for template in leaderLineTemplates { template.build(builder) }
            if let style: MultiLeaderStyle = builder.tryGetObject(leaderStyleHandle) { leader.style = style }
            if let lineType: LineType = builder.tryGetObject(leaderLineTypeHandle) { leader.leaderLineType = lineType }
            if let style: TextStyle = builder.tryGetObject(mtextStyleHandle) { leader.textStyle = style }
            if let block: BlockRecord = builder.tryGetObject(blockContentHandle) { leader.blockContent = block }
            if let arrow: BlockRecord = builder.tryGetObject(arrowheadHandle) { leader.arrowhead = arrow }
            for (i, handle) in blockAttributeHandles.enumerated() where i < leader.blockAttributes.count {
                leader.blockAttributes[i].attributeHandle = handle
                if let definition: AttributeDefinition = builder.tryGetObject(handle) {
                    leader.blockAttributes[i].attributeDefinition = definition
                }
            }
            // ACadSharp 3.8 does not build the arrowhead overrides (a TODO there).
        }
    }

    final class CadShapeTemplate: CadEntityTemplate {
        var shapeIndex: UInt16?
        var shapeFileHandle: UInt64?
        var shapeFileName: String?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let shape = cadObject as! Shape
            if let style: TextStyle = tableReference(builder, shapeFileHandle, shapeFileName) {
                if style.isShapeFile {
                    shape.shapeStyle = style
                } else {
                    builder.notify("Shape style \(shapeFileHandle.map(String.init) ?? "") | \(shapeFileName ?? "") not found")
                }
            }
        }
    }

    final class CadToleranceTemplate: CadEntityTemplate {
        var dimensionStyleHandle: UInt64?
        var dimensionStyleName: String?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let style: DimensionStyle = tableReference(builder, dimensionStyleHandle, dimensionStyleName) {
                (cadObject as! Tolerance).style = style
            }
        }
    }

    final class CadViewportTemplate: CadEntityTemplate {
        var viewportHeaderHandle: UInt64?
        var boundaryHandle: UInt64?
        var namedUcsHandle: UInt64?
        var baseUcsHandle: UInt64?
        var visualStyleHandle: UInt64?
        var viewportId: Int16?
        var blockHandle: UInt64?
        var frozenLayerHandles = HandleSet()

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let viewport = cadObject as! Viewport
            if let boundary: Entity = builder.tryGetObject(boundaryHandle) {
                viewport.boundary = boundary
            } else if (boundaryHandle ?? 0) > 0 {
                builder.notify("Boundary \(boundaryHandle!) not found for viewport \(viewport.handle)")
            }
            for handle in frozenLayerHandles {
                if let layer: Layer = builder.tryGetObject(handle) {
                    viewport.frozenLayers.append(layer)
                } else {
                    builder.notify("Frozen layer \(handle) not found for viewport \(viewport.handle)")
                }
            }
        }
    }

    final class CadWipeoutBaseTemplate: CadEntityTemplate {
        var imgDefHandle: UInt64?
        var imgReactorHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let image = cadObject as! CadWipeoutBase
            if let definition: ImageDefinition = builder.tryGetObject(imgDefHandle) { image.definition = definition }
            if let reactor: ImageDefinitionReactor = builder.tryGetObject(imgReactorHandle) { image.definitionReactor = reactor }
        }
    }

    final class CadUnderlayTemplate: CadEntityTemplate {
        var definitionHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let definition: PdfUnderlayDefinition = builder.tryGetObject(definitionHandle) {
                (cadObject as! PdfUnderlay).definition = definition
            } else {
                builder.notify("UnderlayDefinition not found for \(cadObject.handle)")
            }
        }
    }

    final class CadOle2FrameTemplate: CadEntityTemplate {
        var chunks: [Data] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let ole = cadObject as! Ole2Frame
            if !chunks.isEmpty { ole.binaryData = chunks.reduce(into: Data()) { $0.append($1) } }
            let data = ole.binaryData
            guard data.count >= 2 + 4 * 3 * 8 else { return }
            func point(_ offset: Int) -> XYZ {
                XYZ(BinaryPrimitives.readDoubleLittleEndian(data, offset), BinaryPrimitives.readDoubleLittleEndian(data, offset + 8),
                    BinaryPrimitives.readDoubleLittleEndian(data, offset + 16))
            }
            ole.upperLeftCorner = point(2)
            ole.lowerRightCorner = point(2 + 48)
        }
    }

    final class CadModelerGeometryTemplate: CadEntityTemplate {
        var historyHandle: UInt64?
        private var acisText = ""
        private var isEncoded: Bool?

        func appendAcisLine(_ chunk: String) {
            if !acisText.isEmpty { acisText.append("\n") }
            append(chunk)
        }

        func appendAcisContinuation(_ chunk: String) { append(chunk) }

        private func append(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            if isEncoded == nil { isEncoded = AcisTextCodec.isEncoded(chunk) }
            acisText.append(isEncoded! ? AcisTextCodec.decode(chunk) : chunk)
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if !acisText.isEmpty, let geometry = cadObject as? ModelerGeometry, geometry.acisData == nil {
                geometry.acisData = Data(acisText.utf8)
            }
        }
    }

    final class CadProxyEntityTemplate: CadEntityTemplate {
        var referencedObjectHandles: [UInt64] = []
    }

    // ───────────────────────── Tables ─────────────────────────

    class CadTableTemplateBase: CadTemplate {
        var entryHandles = HandleSet()
    }

    final class CadTableTemplate<T: TableEntry>: CadTableTemplateBase {
        var table: Table<T> { cadObject as! Table<T> }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            for handle in entryHandles {
                guard let entry: T = builder.tryGetObject(handle) else { continue }
                if table.contains(entry.name), !(table is VPortsTable) {
                    builder.notify("[\(table.subclassMarker)] the entry \(entry.name) already exists")
                    continue
                }
                table.add(entry)
            }
            if let blocks = self as? CadTableTemplate<BlockRecord>, let ctrl = blocks.blockControl {
                if let model: BlockRecord = builder.tryGetObject(ctrl.modelSpaceHandle) { addIfMissing(model as! T) }
                if let paper: BlockRecord = builder.tryGetObject(ctrl.paperSpaceHandle) { addIfMissing(paper as! T) }
            }
        }

        private func addIfMissing(_ entry: T) {
            if !table.contains(entry.name) { table.add(entry) }
        }

        /// DWG block control object extras (`CadBlockCtrlObjectTemplate`).
        final class BlockControl {
            var modelSpaceHandle: UInt64?
            var paperSpaceHandle: UInt64?
        }

        var blockControl: BlockControl?
    }

    class CadTableEntryTemplate: CadTemplate {
        var entry: TableEntry { cadObject as! TableEntry }
        var name: String { entry.name }
    }

    final class CadBlockRecordTemplate: CadTableEntryTemplate, CadOwnerTemplate {
        var beginBlockHandle: UInt64?
        var blockEntityTemplate: CadBlockEntityTemplate?
        var endBlockHandle: UInt64?
        var firstEntityHandle: UInt64?
        var insertHandles: [UInt64] = []
        var lastEntityHandle: UInt64?
        var layoutHandle: UInt64?
        var ownedObjectsHandlers = HandleSet()
        var referenceTemplates: [CadEntityTemplate] = []

        var record: BlockRecord { cadObject as! BlockRecord }

        /// `SetBlockToRecord` (DWG): the record takes over the BLOCK / ENDBLK objects read separately.
        func setBlockToRecord(_ builder: CadDocumentBuilder, modelSpace: UInt64?, paperSpace: UInt64?) {
            if let block: Block = builder.tryGetObject(beginBlockHandle) {
                if !block.name.isEmpty { record.name = block.name }
                let current = record.blockEntity
                block.blockFlags = current.blockFlags
                block.basePoint = current.basePoint
                block.xRefPath = current.xRefPath
                block.comments = current.comments
                block.isUnloaded = current.isUnloaded
                record.setBlockEntity(block)
            }
            if let end: BlockEnd = builder.tryGetObject(endBlockHandle) { record.setBlockEnd(end) }
            ensureName(builder, modelSpace, BlockRecord.modelSpaceName)
            ensureName(builder, paperSpace, BlockRecord.paperSpaceName)
        }

        private func ensureName(_ builder: CadDocumentBuilder, _ handle: UInt64?, _ expected: String) {
            if record.handle == handle, record.name.caseInsensitiveCompare(expected) != .orderedSame {
                builder.notify("Invalid name for \(record.name) changed to \(expected)")
                record.name = expected
            }
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let layout: Layout = builder.tryGetObject(layoutHandle) { record.layout = layout }
            if let first = firstEntityHandle, first != 0 {
                for entity in entitiesCollection(builder, first: first, end: lastEntityHandle ?? first) { add(builder, entity) }
            } else {
                if let blockTemplate = blockEntityTemplate { ownedObjectsHandlers.formUnion(blockTemplate.ownedObjectsHandlers) }
                for handle in ownedObjectsHandlers {
                    if let entity: Entity = builder.tryGetObject(handle) { add(builder, entity) }
                }
            }
            for template in referenceTemplates { add(builder, template.entity) }
        }

        private func add(_ builder: CadDocumentBuilder, _ entity: Entity) {
            if entity is UnknownEntity { return }
            record.entities.add(entity)
        }
    }

    final class CadLayerTemplate: CadTableEntryTemplate {
        var layerControlHandle: UInt64 = 0
        var plotStyleHandle: UInt64 = 0
        var materialHandle: UInt64 = 0
        var lineTypeHandle: UInt64?
        var lineTypeName: String?
        var trueColorName: String?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let lineType: LineType = tableReference(builder, lineTypeHandle, lineTypeName) {
                (cadObject as! Layer).lineType = lineType
            } else {
                builder.notify("Linetype with handle \(lineTypeHandle.map(String.init) ?? "") could not be found for layer \(name)")
            }
        }
    }

    final class CadLineTypeTemplate: CadTableEntryTemplate {
        final class SegmentTemplate {
            var styleHandle: UInt64?
            let segment = LineType.Segment()
        }

        var ltypeControlHandle: UInt64?
        var totalLen: Double?
        var segmentTemplates: [SegmentTemplate] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let lineType = cadObject as! LineType
            for template in segmentTemplates {
                if let style: TextStyle = builder.tryGetObject(template.styleHandle) { template.segment.style = style }
                lineType.addSegment(template.segment)
            }
        }
    }

    final class CadDimensionStyleTemplate: CadTableEntryTemplate {
        var dimblName: String?
        var dimblk: UInt64?
        var dimblk1: UInt64?
        var dimblk1Name: String?
        var dimblk2: UInt64?
        var dimblk2Name: String?
        var dimldrblk: UInt64?
        var dimltex1: UInt64 = 0
        var dimltex2: UInt64 = 0
        var dimltype: UInt64?
        var textStyleName: String?
        var textStyleHandle: UInt64?
        var blockHandle: UInt64?
        var dxfFlagsAssigned = false

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let style = cadObject as! DimensionStyle
            if let textStyle: TextStyle = tableReference(builder, textStyleHandle, textStyleName) { style.style = textStyle }
            if let lt: LineType = tableReference(builder, dimltype, nil) { style.lineType = lt }
            if let lt: LineType = tableReference(builder, dimltex1, nil) { style.lineTypeExt1 = lt }
            if let lt: LineType = tableReference(builder, dimltex2, nil) { style.lineTypeExt2 = lt }
            // ACadSharp 3.8 resolves DIMLDRBLK with the DIMBLK name and never assigns ArrowBlock.
            if let b: BlockRecord = tableReference(builder, dimldrblk, dimblName) { style.leaderArrow = b }
            if let b: BlockRecord = tableReference(builder, dimblk1, dimblk1Name) { style.dimArrow1 = b }
            if let b: BlockRecord = tableReference(builder, dimblk2, dimblk2Name) { style.dimArrow2 = b }
            let _: BlockRecord? = tableReference(builder, blockHandle, nil)
        }
    }

    final class CadVPortTemplate: CadTableEntryTemplate {
        var vportControlHandle: UInt64 = 0
        var backgroundHandle: UInt64?
        var styleHandle: UInt64?
        var sunHandle: UInt64?
        var namedUcsHandle: UInt64?
        var baseUcsHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let vport = cadObject as! VPort
            if let ucs: UCS = builder.tryGetObject(baseUcsHandle) {
                vport.baseUcs = ucs
            } else if (baseUcsHandle ?? 0) > 0 {
                builder.notify("Boundary \(baseUcsHandle!) not found for viewport \(vport.handle)")
            }
            // ACadSharp assigns the named UCS to BaseUcs as well.
            if let ucs: UCS = builder.tryGetObject(namedUcsHandle) {
                vport.baseUcs = ucs
            } else if (namedUcsHandle ?? 0) > 0 {
                builder.notify("Boundary \(baseUcsHandle.map(String.init) ?? "") not found for viewport \(vport.handle)")
            }
        }
    }

    final class CadViewTemplate: CadTableEntryTemplate {
        var visualStyleHandle: UInt64?
        var namedUcsHandle: UInt64?
        var ucsHandle: UInt64?
    }

    // ───────────────────────── Objects ─────────────────────────

    class CadDictionaryTemplate: CadTemplate {
        /// Entry names and handles in reading order (a .NET Dictionary keyed by name: the first name wins).
        var entries: [(String, UInt64?)] = []

        func addEntryName(_ name: String) {
            if entries.contains(where: { $0.0 == name }) { return }
            entries.append((name, nil))
        }

        func setLastEntryHandle(_ handle: UInt64) {
            guard !entries.isEmpty else {
                entries.append(("", handle))
                return
            }
            entries[entries.count - 1].1 = handle
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let dictionary = cadObject as! CadDictionary
            if ownerHandle == 0, builder.document.rootDictionary == nil {
                builder.document.setRootDictionary(dictionary)
            }
            for (key, handle) in entries {
                if let entry: NonGraphicalObject = builder.tryGetObject(handle) {
                    if entry.name.isEmpty { entry.name = key }
                    if dictionary.containsKey(entry.name) {
                        builder.notify("Error when trying to add the entry \(entry.name) to \(dictionary.name)|\(dictionary.handle)")
                        continue
                    }
                    dictionary.add(entry.name, entry)
                } else {
                    builder.notify("Entry not found \(key)|\(handle.map(String.init) ?? "") for dictionary \(dictionary.name)|\(dictionary.handle)")
                }
            }
        }
    }

    final class CadDictionaryWithDefaultTemplate: CadDictionaryTemplate {
        var defaultEntryHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            if let entry: CadObject = builder.tryGetObject(defaultEntryHandle) {
                (cadObject as! CadDictionaryWithDefault).defaultEntry = entry
            }
        }
    }

    final class CadLayoutTemplate: CadTemplate {
        var paperSpaceBlockHandle: UInt64?
        var activeViewportHandle: UInt64?
        var baseUcsHandle: UInt64?
        var namesUcsHandle: UInt64?
        var lastActiveViewportHandle: UInt64?
        var viewportHandles = HandleSet()

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let layout = cadObject as! Layout
            if let record: BlockRecord = builder.tryGetObject(paperSpaceBlockHandle) { layout.associatedBlock = record }
            if let viewport: Viewport = builder.tryGetObject(activeViewportHandle) { layout.lastActiveViewport = viewport }
            if let ucs: UCS = builder.tryGetObject(baseUcsHandle) { layout.baseUCS = ucs }
            if let ucs: UCS = builder.tryGetObject(namesUcsHandle) { layout.ucs = ucs }
        }
    }

    final class CadGroupTemplate: CadTemplate {
        var handles = HandleSet()

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let group = cadObject as! Group
            for handle in handles {
                if let template: CadEntityTemplate = builder.objectTemplate(handle) {
                    template.build(builder)
                    // Group.Add: both in the same document; the group becomes a reactor of the entity (again if
                    // the file already lists it).
                    if group.document !== template.entity.document {
                        builder.notify("Entity with handle \(handle) could not be added to group \(group.handle)")
                    } else {
                        group.entities.append(template.entity)
                        template.entity.addReactor(group.handle)
                    }
                } else {
                    builder.notify("Entity with handle \(handle) not found for group \(group.handle)")
                }
            }
        }
    }

    final class CadXRecordTemplate: CadTemplate {
        /// Handle entries, appended after the other entries once their objects are found (`AddHandleReference`).
        var handleReferences: [(code: Int, handle: UInt64)] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let record = cadObject as! XRecord
            for (code, handle) in handleReferences {
                if builder.tryGetObject(handle) as CadObject? != nil {
                    record.entries.append(.init(code: code, value: .handle(handle)))
                } else {
                    builder.notify("XRecord reference not found \(code)|\(handle)")
                }
            }
        }
    }

    final class CadSortensTableTemplate: CadTemplate {
        var blockOwnerHandle: UInt64?
        var values: [(UInt64?, UInt64?)] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let table = cadObject as! SortEntitiesTable
            if let owner: CadObject = builder.tryGetObject(blockOwnerHandle) {
                guard let record = owner as? BlockRecord else {
                    builder.notify("Block owner for SortEntitiesTable \(table.handle) is not a block \(owner.objectName) | \(owner.handle)")
                    return
                }
                table.blockOwner = record
            }
            for (sort, entityHandle) in values {
                if let entity: Entity = builder.tryGetObject(entityHandle) {
                    table.add(entity, sortHandle: sort ?? 0)
                } else {
                    builder.notify("Entity in SortEntitiesTable \(table.handle) not found \(entityHandle.map(String.init) ?? "")")
                }
            }
        }
    }

    final class CadMLineStyleTemplate: CadTemplate {
        final class ElementTemplate {
            let element: MLineStyle.Element
            var lineTypeHandle: UInt64?
            var lineTypeIndex: Int32?
            var lineTypeName: String?
            init(_ element: MLineStyle.Element) { self.element = element }

            func build(_ builder: CadDocumentBuilder) {
                if let lineType: LineType = builder.tryGetObject(lineTypeHandle) {
                    element.lineType = lineType
                } else if let name = lineTypeName, let lineType: LineType = builder.tableEntry(name) {
                    element.lineType = lineType
                } else if let index = lineTypeIndex {
                    if index == Int32(Int16.max) {
                        if let lineType = builder.lineTypes[LineType.byLayerName] { element.lineType = lineType }
                    } else if index == Int32(Int16.max) - 1 {
                        if let lineType = builder.lineTypes[LineType.byBlockName] { element.lineType = lineType }
                    } else if index >= 0, Int(index) < builder.lineTypes.count {
                        element.lineType = builder.lineTypes.entries[Int(index)]
                    } else {
                        builder.notify("Linetype not assigned, index \(index)")
                    }
                }
            }
        }

        var elementTemplates: [ElementTemplate] = []

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            for template in elementTemplates { template.build(builder) }
        }
    }

    final class CadMLeaderStyleTemplate: CadTemplate {
        var arrowheadHandle: UInt64?
        var blockContentHandle: UInt64?
        var leaderLineTypeHandle: UInt64?
        var mtextStyleHandle: UInt64?

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let style = cadObject as! MultiLeaderStyle
            if let lineType: LineType = builder.tryGetObject(leaderLineTypeHandle) { style.leaderLineType = lineType }
            if let block: BlockRecord = builder.tryGetObject(arrowheadHandle) { style.arrowhead = block }
            if let text: TextStyle = builder.tryGetObject(mtextStyleHandle) { style.textStyle = text }
            if let block: BlockRecord = builder.tryGetObject(blockContentHandle) { style.blockContent = block }
        }
    }


    /// Plain objects with nothing to resolve beyond the common data (`CadNonGraphicalObjectTemplate`).
    final class CadNonGraphicalObjectTemplate: CadTemplate {}
}
