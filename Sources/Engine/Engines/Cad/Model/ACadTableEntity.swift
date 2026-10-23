// ACAD_TABLE entities of the CAD document model (ACadSharp TableEntity with its TableContent): rows, columns,
// cells and their style overrides. Tables are drawn through their anonymous block; the cell data is what the
// DWG writer stores.

import Foundation

extension ACad {
    /// `TableEntity` (ACAD_TABLE).
    final class TableEntity: Insert, DxfClassDefined {
        /// `TableEntity.CellType`.
        enum CellType { static let text: Int32 = 1, block: Int32 = 2 }

        /// `TableEntity.TableCellContentType`.
        enum TableCellContentType {
            static let unknown: Int32 = 0, value: Int32 = 1, field: Int32 = 2, block: Int32 = 4
        }

        /// `TableEntity.CellContent`.
        final class CellContent {
            var contentType: Int32 = 0
            let format = TableStyle.ContentFormat()
            let cadValue = CadValue()
        }

        /// `TableEntity.CellContentGeometry`.
        final class CellContentGeometry {
            var distanceTopLeft = XYZ.zero
            var distanceCenter = XYZ.zero
            var contentWidth = 0.0
            var contentHeight = 0.0
            var width = 0.0
            var height = 0.0
            var flags: Int32 = 0
        }

        /// `TableEntity.CustomDataEntry`.
        final class CustomDataEntry {
            var name: String?
            var value = CadValue()
        }

        /// `TableEntity.Cell`.
        final class Cell {
            var autoFit = false
            var blockScale = 0.0
            var borderHeight: Int32 = 0
            var borderWidth: Int32 = 0
            var contents: [CellContent] = []
            var customData: Int32 = 0
            var customDataCollection: [CustomDataEntry] = []
            var edgeFlags: Int16 = 0
            var geometry: CellContentGeometry?
            var hasLinkedData = false
            var mergedValue: Int16 = 0
            var rotation = 0.0
            /// `TableCellStateFlags` (90).
            var stateFlags: Int32 = 0
            var style: TableStyle.CellStyle?
            let styleOverride: TableStyle.CellStyle = {
                let style = TableStyle.CellStyle()
                style.hasData = false
                return style
            }()
            var toolTip: String?
            /// `CellType` (171).
            var type: Int32 = 0
            var virtualEdgeFlag: Int16 = 0

            var hasMultipleContent: Bool { contents.count > 1 }
            /// The single content (nil for none or several).
            var content: CellContent? { hasMultipleContent ? nil : contents.first }
        }

        /// The rows and columns (`ITableComponent`).
        class Component {
            var cellStyle: TableStyle.CellStyle?
            var cellStyleOverride = TableStyle.CellStyle()
            var customData: Int32 = 0
            var customDataCollection: [CustomDataEntry] = []
        }

        final class Column: Component {
            var name = ""
            var width = 1.0
        }

        final class Row: Component {
            var cells: [Cell] = []
            var height = 1.0
        }

        /// `TableEntity.CellRange`.
        final class CellRange {
            var bottomRowIndex: Int32 = 0
            var leftColumnIndex: Int32 = 0
            var rightColumnIndex: Int32 = 0
            var topRowIndex: Int32 = 0
        }

        /// `TableEntity.TableBreakData`.
        final class TableBreakData {
            struct BreakHeight {
                var height = 0.0
                var position = XYZ.zero
            }

            var breakSpacing = 0.0
            /// `BreakOptionFlags`.
            var flags: Int32 = 0
            /// `BreakFlowDirection`.
            var flowDirection: Int32 = 0
            var heights: [BreakHeight] = []
        }

        /// `TableEntity.BreakRowRange`.
        final class BreakRowRange {
            var position = XYZ.zero
            var startRowIndex: Int32 = 0
            var endRowIndex: Int32 = 0
        }

        let breakData = TableBreakData()
        var hasBreadData = false
        var horizontalDirection = XYZ.zero
        var overrideBorderColor = false
        var overrideBorderLineWeight = false
        var overrideBorderVisibility = false
        var overrideFlag = false
        var valueFlag: Int32 = 0
        var version: Int16 = 0
        var breakRowRanges: [BreakRowRange] = []
        var content = TableContent()

        var columns: [Column] {
            get { content.columns }
            set { content.columns = newValue }
        }
        var rows: [Row] {
            get { content.rows }
            set { content.rows = newValue }
        }
        var style: TableStyle {
            get { content.style }
            set { content.style = newValue }
        }
        var mergedCellRanges: [CellRange] { content.mergedCellRanges }
        var cellStyleOverride: TableStyle.CellStyle { content.cellStyleOverride }
        var tableBlock: BlockRecord? { block }

        override var objectName: String { DxfFileToken.entityTable }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.tableEntity }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.tableEntity, DxfFileToken.entityTable, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 498, maintenance: 0, proxyFlags: ProxyFlags.eraseAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }

    /// `LinkedData` → `LinkedTableData` → `FormattedTableData` → `TableContent` (TABLECONTENT).
    class LinkedData: NonGraphicalObject {
        var description: String?
        override var subclassMarker: String { DxfSubclassMarker.linkedData }
    }

    class LinkedTableData: LinkedData {
        var rows: [TableEntity.Row] = []
        var columns: [TableEntity.Column] = []
        override var subclassMarker: String { DxfSubclassMarker.linkedTableData }
    }

    class FormattedTableData: LinkedTableData {
        var mergedCellRanges: [TableEntity.CellRange] = []
        var cellStyleOverride = TableStyle.CellStyle()
        override var subclassMarker: String { DxfSubclassMarker.formattedTableData }
    }

    final class TableContent: FormattedTableData, DxfClassDefined {
        var style = TableStyle.makeDefault()
        var styleOverride: TableStyle?

        override var objectName: String { DxfFileToken.objectTableContent }
        override var objectType: ObjectType { .unlisted }
        override var subclassMarker: String { DxfSubclassMarker.tableContent }

        func dxfClass() -> DxfClass {
            DxfClass(DxfSubclassMarker.tableContent, DxfFileToken.objectTableContent, dwgVersion: Version.ac1018.rawValue,
                     itemClassId: 499, maintenance: 21, proxyFlags: ProxyFlags.cloningAllowed | ProxyFlags.disablesProxyWarningDialog)
        }
    }
}
