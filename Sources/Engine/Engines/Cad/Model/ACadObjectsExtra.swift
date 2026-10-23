// More non-graphical objects of the CAD document model (ACadSharp Objects): dimension associativity, block
// representation data, geographic data, fields, proxy objects and the annotation-scale context data.

import Foundation

extension ACad {
    // ───────────────────────── Dimension associativity ─────────────────────────

    /// `DimensionAssociation` (DIMASSOC).
    final class DimensionAssociation: NonGraphicalObject, DxfClassDefined {
        static let osnapPointRefClassName = "AcDbOsnapPointRef"

        /// `AssociativityFlags`.
        enum Flags {
            static let firstPointReference: Int16 = 1, secondPointReference: Int16 = 2
            static let thirdPointReference: Int16 = 4, fourthPointReference: Int16 = 8
        }

        /// `OsnapPointRef`.
        final class OsnapPointRef {
            var geometryParameter = 0.0
            /// `ObjectOsnapType` (72).
            var objectOsnapType: Int16 = 0
            var osnapPoint = XYZ.zero
            /// `SubentType` (73).
            var subentType: Int16 = 0
            var gsMarker: Int32 = 0
            var intersectionSubType: Int16 = 0
            var intersectionGsMarker: Int32 = 0
            var hasLastPointRef = false
            var geometry: CadObject?
        }

        /// `AssociativityFlags` (90).
        var associativityFlags: Int16 = 0
        weak var dimension: Dimension?
        var firstPointRef: OsnapPointRef?
        var fourthPointRef: OsnapPointRef?
        var isTransSpace = false
        /// `RotatedDimensionType` (71).
        var rotatedDimensionType: Int16 = 0
        var secondPointRef: OsnapPointRef?
        var thirdPointRef: OsnapPointRef?

        override var objectName: String { DxfFileToken.objectDimensionAssociation }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.dimensionAssociation }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.dimensionAssociation, DxfFileToken.objectDimensionAssociation, dwgVersion: 0,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.none, application: "AcDbDimAssoc")
        }
    }

    // ───────────────────────── Block data ─────────────────────────

    /// `DynamicBlockPurgePreventer`.
    final class DynamicBlockPurgePreventer: NonGraphicalObject, DxfClassDefined {
        var version: Int16 = 0
        /// Not stored in DXF.
        weak var block: BlockRecord?

        override var objectName: String { DxfFileToken.objectDynamicBlockPurgePreventer }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.acDbDynamicBlockPurgePreventer }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.acDbDynamicBlockPurgePreventer, DxfFileToken.objectDynamicBlockPurgePreventer,
                     dwgVersion: Version.ac1018.rawValue, itemClassId: 499, maintenance: 61,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    /// `BlockRepresentationData`.
    final class BlockRepresentationData: NonGraphicalObject, DxfClassDefined {
        weak var block: BlockRecord?
        var version: Int16 = 0

        override var objectName: String { DxfFileToken.objectBlockRepresentationData }
        override var subclassMarker: String { DxfSubclassMarker.blockRepresentationData }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.blockRepresentationData, DxfFileToken.objectBlockRepresentationData,
                     dwgVersion: Version.ac1018.rawValue, itemClassId: 499, maintenance: 58,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    // ───────────────────────── Geographic data ─────────────────────────

    /// `GeoData`.
    final class GeoData: NonGraphicalObject, DxfClassDefined {
        /// `GeoDataVersion`.
        enum GeoDataVersion {
            static let r2009: Int32 = 1, r2010: Int32 = 2, r2013: Int32 = 3
        }

        struct GeoMeshPoint {
            var source = XY.zero
            var destination = XY.zero
        }

        struct GeoMeshFace {
            var index1: Int32 = 0, index2: Int32 = 0, index3: Int32 = 0
        }

        var coordinateProjectionRadius = 0.0
        /// `DesignCoordinatesType` (70): local grid.
        var coordinatesType: Int16 = 1
        var coordinateSystemDefinition = ""
        var designPoint = XYZ.zero
        var enableSeaLevelCorrection = false
        var faces: [GeoMeshFace] = []
        var geoRssTag = ""
        /// `UnitsType` (91): meters.
        var horizontalUnits: Int32 = 6
        var horizontalUnitScale = 1.0
        private var _hostBlock: BlockRecord?
        var hostBlock: BlockRecord? {
            get { _hostBlock }
            set {
                guard let newValue else { return }
                _hostBlock = document.map { $0.blockRecords.resolve(newValue) } ?? newValue
            }
        }
        var northDirection = XY(0, 1)
        var observationCoverageTag = ""
        var observationFromTag = ""
        var observationToTag = ""
        var points: [GeoMeshPoint] = []
        var referencePoint = XYZ.zero
        /// `ScaleEstimationType` (95): none.
        var scaleEstimationMethod: Int32 = 1
        var seaLevelElevation = 0.0
        var upDirection = XYZ.axisZ
        var userSpecifiedScaleFactor = 0.0
        var version: Int32 = GeoDataVersion.r2013
        /// `UnitsType` (92): meters.
        var verticalUnits: Int32 = 6
        var verticalUnitScale = 1.0

        override var objectName: String { DxfFileToken.objectGeoData }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.geoData }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.geoData, DxfFileToken.objectGeoData, dwgVersion: Version.ac1021.rawValue,
                     itemClassId: 499, maintenance: 45, proxyFlags: 4095)
        }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            if let block = _hostBlock { _hostBlock = document.blockRecords.resolve(block) }
        }
    }

    // ───────────────────────── Fields ─────────────────────────

    /// `CadValueType`.
    enum CadValueType {
        static let unknown: Int32 = 0, long: Int32 = 1, double: Int32 = 2, string: Int32 = 4, date: Int32 = 8
        static let point2D: Int32 = 0x10, point3D: Int32 = 0x20, handle: Int32 = 0x40, buffer: Int32 = 0x80
        static let resultBuffer: Int32 = 0x100, general: Int32 = 0x200
    }

    /// `CadValue`: a typed value of a field or table cell.
    final class CadValue {
        enum Value {
            case int(Int32), double(Double), string(String), date(Date), point2D(XY), point3D(XYZ), object(CadObject)
        }

        struct InvalidValue: Error, CustomStringConvertible {
            var description: String { "Operation is not valid due to the current state of the object." }
        }

        var flags: Int32 = 0
        var format: String?
        var formattedValue: String?
        /// `CadValueUnitType` (94).
        var units: Int32 = 0
        private(set) var value: Value?
        var valueType: Int32 = 0

        var isEmpty: Bool {
            get { flags & 1 != 0 }
            set { flags = newValue ? flags | 1 : flags & ~1 }
        }

        /// `SetValue`: the value must match the value type (vectors are converted), else ACadSharp throws.
        func setValue(_ newValue: Value) throws {
            switch (valueType, newValue) {
            case (CadValueType.point2D, .point2D(let v)): value = .point2D(v)
            case (CadValueType.point2D, .point3D(let v)): value = .point2D(v.xy)
            case (CadValueType.point3D, .point2D(let v)): value = .point3D(XYZ(v.x, v.y, 0))
            case (CadValueType.point3D, .point3D(let v)): value = .point3D(v)
            case (CadValueType.long, .int), (CadValueType.double, .double), (CadValueType.date, .date),
                 (CadValueType.handle, .object), (CadValueType.string, .string), (CadValueType.general, .string):
                value = newValue
            case (CadValueType.unknown, _):
                value = newValue
            default:
                throw InvalidValue()
            }
        }

        func setValue(_ newValue: Value, type: Int32) throws {
            valueType = type
            try setValue(newValue)
        }
    }

    /// `Field`.
    final class Field: NonGraphicalObject, DxfClassDefined {
        var cadObjects: [CadObject] = []
        private(set) lazy var children = CadObjectCollection<Field>(owner: self)
        var evaluationErrorCode: Int32 = 0
        var evaluationErrorMessage: String?
        /// `EvaluationOptionFlags` (91).
        var evaluationOptionFlags: Int32 = 0
        /// `EvaluationStatusFlags` (95).
        var evaluationStatusFlags: Int32 = 0
        var evaluatorId: String?
        var fieldCode: String?
        /// `FieldStateFlags` (94).
        var fieldStateFlags: Int32 = 0
        /// `FilingOptionFlags` (92).
        var filingOptionFlags: Int32 = 0
        var formatString: String?
        var value = CadValue()
        /// Keyed without case (`InvariantCultureIgnoreCase`).
        var values = NameMap<CadValue>()

        override var objectName: String { DxfFileToken.objectField }
        override var subclassMarker: String { DxfSubclassMarker.field }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.field, DxfFileToken.objectField, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            for child in children { document.addCadObject(child) }
        }
    }

    /// `FieldList`.
    final class FieldList: NonGraphicalObject, DxfClassDefined {
        var fields: [Field] = []

        override var objectName: String { DxfFileToken.objectFieldList }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.fieldList }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.fieldList, DxfFileToken.objectFieldList, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 499, maintenance: 0, proxyFlags: ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    // ───────────────────────── Proxies ─────────────────────────

    /// `ProxyObject` (ACAD_PROXY_OBJECT).
    final class ProxyObject: NonGraphicalObject {
        var dxfClass: DxfClass?
        var maintenanceVersion: Int32 = 0
        var originalDataFormatDxf = false
        let proxyClassId: Int32 = 499
        var binaryData: Data?
        var data: Data?
        var version: Version = .unknown

        var classId: Int32 { Int32(dxfClass?.classNumber ?? 0) }
        var drawingFormat: Int32 { Int32(version.rawValue) | (maintenanceVersion << 16) }

        override var objectName: String { DxfFileToken.objectProxyObject }
        override var subclassMarker: String { DxfSubclassMarker.proxyObject }
    }

    // ───────────────────────── Context data ─────────────────────────

    /// `ObjectContextData`.
    class ObjectContextData: NonGraphicalObject {
        var version: Int16 = 3
        var hasFileToExtensionDictionary = true
        var `default` = false
        override var subclassMarker: String { DxfSubclassMarker.objectContextData }
    }

    /// `AnnotScaleObjectContextData`: the annotation scale belongs to the document's scale list.
    class AnnotScaleObjectContextData: ObjectContextData {
        private var _scale = Scale.makeDefault()
        var scale: Scale {
            get { _scale }
            set { _scale = document?.scales.map { $0.resolve(newValue) } ?? newValue }
        }

        override var subclassMarker: String { DxfSubclassMarker.annotScaleObjectContextData }

        override func assignDocument(_ document: Document) {
            super.assignDocument(document)
            if let scales = document.scales { _scale = scales.resolve(_scale) }
        }
    }

    /// `BlockReferenceObjectContextData`.
    final class BlockReferenceObjectContextData: AnnotScaleObjectContextData, DxfClassDefined {
        var insertionPoint = XYZ.zero
        var rotation = 0.0
        var xScale = 1.0, yScale = 1.0, zScale = 1.0

        override var objectName: String { DxfFileToken.blkRefObjectContextData }
        override var subclassMarker: String { DxfSubclassMarker.annotScaleObjectContextData }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.blkRefObjectContextData, DxfFileToken.blkRefObjectContextData,
                     dwgVersion: Version.ac1021.rawValue, itemClassId: 499, maintenance: 0,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    /// `MTextAttributeObjectContextData`.
    final class MTextAttributeObjectContextData: AnnotScaleObjectContextData, DxfClassDefined {
        var alignmentPoint = XYZ.axisX
        /// `AttachmentPointType` (70): top left.
        var attachmentPoint: Int16 = 1
        var insertPoint = XYZ.zero
        var rotation = 0.0
        var value290 = false

        override var objectName: String { DxfFileToken.mTextAttributeObjectContextData }
        override var subclassMarker: String { DxfSubclassMarker.annotScaleObjectContextData }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.mTextAttributeObjectContextData, DxfFileToken.mTextAttributeObjectContextData,
                     dwgVersion: Version.ac1021.rawValue, itemClassId: 499, maintenance: 0,
                     proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    /// `UnknownNonGraphicalObject`: an object of a class ACadSharp does not read.
    final class UnknownNonGraphicalObject: NonGraphicalObject {
        let dxfClass: DxfClass?
        init(dxfClass: DxfClass?) {
            self.dxfClass = dxfClass
            super.init()
        }

        override var objectName: String { dxfClass?.dxfName ?? "UNKNOWN" }
        override var subclassMarker: String { dxfClass?.cppClassName ?? DxfSubclassMarker.entity }
        override var objectType: ObjectType { .undefined }
    }
}
