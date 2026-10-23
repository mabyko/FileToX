// Stand-ins for the per-type readers that are not ported yet; each port removes its stubs from this file.

import Foundation

extension ACad.DwgObjectReader {
    func readAcmBalloon() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readAcmPartList() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readAcmPartRef() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readAecCleanupGroup() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readAecWall() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readAecWallStyle() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readAlignmentGrip() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlkRefObjectContextData() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockAlignmentParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockArrayAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockBasePointParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockFlipAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockFlipParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockGrip(_ grip: ACad.BlockGrip) throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockGripLocationComponent() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockLinearParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockLookupAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockLookupParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockMoveAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockPointParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockPolarParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockPolarStretchAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockRepresentationData() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockRotateAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockRotationParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockScaleAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockStretchAction() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockVisibilityParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readBlockXYParameter() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readDimensionAssociation() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readDynamicBlockPurgePreventer() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readEvaluationGraph() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readField() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readFieldList() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readFlipGrip() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readLinearGrip() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readMTextAttributeObjectContextData() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readMultiLeader() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readMultiLeaderAnnotContext() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readMultiLeaderStyle() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readTableEntity() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
    func readTableStyle() throws -> ACad.CadTemplate? { throw ACad.DwgError.notImplemented }
}
