// AEC (Architecture) and AutoCAD Mechanical objects of the CAD document model (ACadSharp Entities.AecEntities,
// Entities.Mechanical, Objects.AEC). Only the DWG reader creates them; the DXF writer skips them and nothing here
// is drawn.

import Foundation

extension ACad {
    /// `AecEntity`.
    class AecEntity: Entity {}

    /// `Wall` (AEC_WALL): the proprietary object data is kept raw.
    final class Wall: AecEntity {
        var baseHeight = 0.0
        var cleanupGroup: AecCleanupGroup?
        var cleanupGroupHandle: UInt64 = 0
        var endPoint = XYZ.zero
        var height = 0.0
        var justification: Int32 = 0
        var length = 0.0
        var normal = XYZ.axisZ
        var rawData: [UInt8]?
        var startPoint = XYZ.zero
        var style: AecWallStyle?
        var version: Int32 = 0
        var width = 0.0

        override var objectName: String { DxfFileToken.entityAecWall }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.aecWall }
    }

    /// `AecWallStyle` (AEC_WALL_STYLE).
    final class AecWallStyle: NonGraphicalObject {
        var version: Int32 = 0
        var description = ""
        var rawData: [UInt8]?

        override var objectName: String { DxfFileToken.objectAecWallStyle }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.aecDbWallStyle }
    }

    /// `AecCleanupGroup` (AEC_CLEANUP_GROUP_DEF).
    final class AecCleanupGroup: NonGraphicalObject {
        var version: Int32 = 0
        var description = ""
        var rawData: [UInt8]?

        override var objectName: String { DxfFileToken.objectAecCleanupGroupDef }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.aecDbCleanupGroupDef }
    }

    /// `MechanicalEntity`.
    class MechanicalEntity: Entity {
        var position = XYZ.zero
    }

    /// `AcmBalloon`.
    final class AcmBalloon: MechanicalEntity {
        var block: BlockRecord?
        override var objectName: String { DxfFileToken.acmBalloon }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.balloon }
    }

    /// `AcmPartList`.
    final class AcmPartList: MechanicalEntity {
        override var objectName: String { DxfFileToken.acmPartList }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.partList }
    }

    /// `AcmPartRef`.
    final class AcmPartRef: MechanicalEntity {
        override var objectName: String { DxfFileToken.acmPartRef }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.partRef }
    }
}
