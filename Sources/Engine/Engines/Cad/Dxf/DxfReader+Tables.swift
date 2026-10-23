// DXF readers for tables (ACadSharp): the ACAD_TABLE entity with its cells, TABLESTYLE objects and TABLECONTENT
// objects. TABLECONTENT data is not kept by ACadSharp (only parsed); its loops are reproduced group by group
// because some of them do not stop at the end of the object and so decide what the following objects are.

import Foundation

extension ACad {
    // ───────────────────────── Templates ─────────────────────────

    /// `CadTableStyleTemplate.CellContentFormatTemplate`.
    class CellContentFormatTemplate {
        let format: TableStyle.ContentFormat
        var textStyleHandle: UInt64?
        var textStyleName: String?
        init(_ format: TableStyle.ContentFormat) { self.format = format }

        func build(_ builder: CadDocumentBuilder) {
            if let style: TextStyle = builder.tryGetObject(textStyleHandle) ?? textStyleName.flatMap({ builder.tableEntry($0) }) {
                format.textStyle = style
            } else if textStyleHandle != nil || !(textStyleName ?? "").isEmpty {
                builder.notify("ACadSharp.Tables.TextStyle table reference with handle: \(textStyleName ?? "") | name: \(textStyleName ?? "") not found for \(type(of: format))")
            }
        }
    }

    /// `CadTableStyleTemplate.CadCellStyleTemplate`.
    final class CadCellStyleTemplate: CellContentFormatTemplate {
        var borderLineTypePairs: [(TableStyle.CellBorder, UInt64)] = []
        var cellStyle: TableStyle.CellStyle { format as! TableStyle.CellStyle }
        init(_ style: TableStyle.CellStyle = TableStyle.CellStyle()) { super.init(style) }
    }

    final class CadTableStyleTemplate: CadTemplate {
        var cellStyleTemplates: [CadCellStyleTemplate] = []
        private(set) var currentCellStyleTemplate: CadCellStyleTemplate?
        var tableCellStyleTemplate: CadCellStyleTemplate?

        @discardableResult
        func createCurrentCellStyleTemplate() -> CadCellStyleTemplate {
            let template = CadCellStyleTemplate()
            currentCellStyleTemplate = template
            cellStyleTemplates.append(template)
            return template
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let style = cadObject as! TableStyle
            tableCellStyleTemplate?.build(builder)
            for template in cellStyleTemplates { template.build(builder) }
            if let data = cellStyle(TableStyle.CellStyle.dataCellStyleName) { style.dataCellStyle = data }
            if let header = cellStyle(TableStyle.CellStyle.headerCellStyleName) { style.headerCellStyle = header }
            if let title = cellStyle(TableStyle.CellStyle.titleCellStyleName) { style.titleCellStyle = title }
        }

        private func cellStyle(_ name: String) -> TableStyle.CellStyle? {
            cellStyleTemplates.first { $0.cellStyle.name?.caseInsensitiveCompare(name) == .orderedSame }?.cellStyle
        }
    }

    /// `CadTableEntityTemplate.CadTableCellTemplate` (its build has no effect for DXF data).
    final class CadTableCellTemplate {
        let cell: TableEntity.Cell
        /// `HashSet<(ulong, string)>` (DWG before R2007).
        var attributeHandles: [(UInt64, String)] = []
        var contentTemplates: [CadTableCellContentTemplate] = []
        var formatTextHeight: Double?
        var styleId: Int32 = 0
        var textStyleOverrideHandle: UInt64?
        var unknownHandle: UInt64?
        var valueHandle: UInt64?
        init(_ cell: TableEntity.Cell) { self.cell = cell }

        /// `Build`: only the contents do something (their attribute templates throw).
        func build(_ builder: CadDocumentBuilder) throws {
            for template in contentTemplates { try template.build(builder) }
        }
    }

    /// `CadTableEntityTemplate.CadTableCellContentTemplate` (DWG).
    final class CadTableCellContentTemplate {
        let content: TableEntity.CellContent
        var attTemplates: [CadTableAttributeTemplate] = []
        var blockRecordHandle: UInt64?
        var fieldHandle: UInt64?
        init(_ content: TableEntity.CellContent) { self.content = content }

        func build(_ builder: CadDocumentBuilder) throws {
            // The CadValueTemplate of a content is never set by the reader.
            for template in attTemplates { try template.build(builder) }
        }
    }

    /// `CadTableEntityTemplate.CadTableAttributeTemplate`: its build is not implemented in ACadSharp 3.8.0.
    final class CadTableAttributeTemplate {
        var attDefHandle: UInt64?
        var value: String?

        func build(_ builder: CadDocumentBuilder) throws { throw DwgError.notImplemented }
    }

    /// `CadTableEntityTemplate.CadTableComponentTemplate`: a row or column with its style overrides (DWG).
    final class CadTableComponentTemplate {
        let component: TableEntity.Component
        var cellStyleTemplate: CadCellStyleTemplate!
        var styleId: Int32 = 0
        init(_ component: TableEntity.Component) { self.component = component }

        func build(_ builder: CadDocumentBuilder, _ table: TableStyle) {
            switch styleId {
            case 1: component.cellStyle = table.titleCellStyle
            case 2: component.cellStyle = table.headerCellStyle
            case 3: component.cellStyle = table.dataCellStyle
            default: break
            }
            cellStyleTemplate.build(builder)
        }
    }

    final class CadTableEntityTemplate: CadInsertTemplate {
        var blockOwnerHandle: UInt64?
        var cellTemplates: [CadTableCellTemplate] = []
        var cellStyleTemplate: CadCellStyleTemplate?
        var componentTemplates: [CadTableComponentTemplate] = []
        var fieldHandles: [UInt64] = []
        var nullHandle: UInt64?
        private(set) var currentCellTemplate: CadTableCellTemplate?
        var horizontalMargin: Double?
        var styleHandle: UInt64?
        private var currentCellIndex = 0

        /// `CurrentCell`: before the first cell this is a null reference in ACadSharp.
        func currentCell() throws -> TableEntity.Cell {
            guard let currentCellTemplate else {
                throw DxfException("Object reference not set to an instance of an object.")
            }
            return currentCellTemplate.cell
        }

        /// `CreateCell`: cells fill the rows column by column.
        func createCell(_ type: Int32) throws {
            let table = cadObject as! TableEntity
            guard !table.columns.isEmpty else { throw DxfException("Attempted to divide by zero.") }
            let rowIndex = currentCellIndex / table.columns.count
            guard rowIndex < table.rows.count else {
                throw DxfException("Index was out of range. Must be non-negative and less than the size of the collection. (Parameter 'index')")
            }
            let cell = TableEntity.Cell()
            cell.type = type
            table.rows[rowIndex].cells.append(cell)
            let template = CadTableCellTemplate(cell)
            currentCellTemplate = template
            cellTemplates.append(template)
            currentCellIndex += 1
        }

        override func buildCore(_ builder: CadDocumentBuilder) {
            super.buildCore(builder)
            let table = cadObject as! TableEntity
            // The table's style is built here, ahead of the other objects.
            if let styleTemplate: CadTableStyleTemplate = builder.objectTemplate(styleHandle) {
                table.style = styleTemplate.cadObject as! TableStyle
                styleTemplate.build(builder)
            } else {
                builder.notify("[TableStyle] \(styleHandle.map(String.init) ?? "") not found for table with handle \(table.handle)")
            }
            do {
                for template in cellTemplates { try template.build(builder) }
            } catch {
                builder.fail("\(error)")
                return
            }
            for component in componentTemplates { component.build(builder, table.style) }
            cellStyleTemplate?.build(builder)
        }
    }

    final class CadTableContentTemplate: CadTemplate {
        var styleHandle: UInt64?
    }
}

extension ACad.DxfReader {
    // ───────────────────────── ACAD_TABLE ─────────────────────────

    /// `readTableEntity`.
    func readTableEntity(_ t: ACad.CadTableEntityTemplate) throws -> Bool {
        typealias E = ACad.TableEntity
        let table = t.cadObject as! E
        switch reader.code {
        case 1:
            let cell = try t.currentCell()
            let content: E.CellContent
            if let existing = cell.content {
                content = existing
            } else {
                content = E.CellContent()
                content.cadValue.valueType = ACad.CadValueType.string
                cell.contents.append(content)
            }
            try appendText(content.cadValue, reader.valueAsString)
        case 2:
            if currentSubclass.caseInsensitiveCompare(ACad.DxfSubclassMarker.tableEntity) == .orderedSame {
                guard let content = try t.currentCell().content else {
                    throw ACad.DxfException("Object reference not set to an instance of an object.")
                }
                try appendText(content.cadValue, reader.valueAsString)
            } else {
                t.blockName = reader.valueAsString
            }
        case 177, 170, 179:
            break
        case 279: try t.currentCell().styleOverride.topBorder.lineWeight = ACad.LineWeight(rawValue: try reader.valueAsShort)
        case 275: try t.currentCell().styleOverride.rightBorder.lineWeight = ACad.LineWeight(rawValue: try reader.valueAsShort)
        case 276: try t.currentCell().styleOverride.bottomBorder.lineWeight = ACad.LineWeight(rawValue: try reader.valueAsShort)
        case 278: try t.currentCell().styleOverride.leftBorder.lineWeight = ACad.LineWeight(rawValue: try reader.valueAsShort)
        case 69: try t.currentCell().styleOverride.topBorder.color = try color(index: reader.valueAsShort)
        case 65: try t.currentCell().styleOverride.rightBorder.color = try color(index: reader.valueAsShort)
        case 66: try t.currentCell().styleOverride.bottomBorder.color = try color(index: reader.valueAsShort)
        case 68: try t.currentCell().styleOverride.leftBorder.color = try color(index: reader.valueAsShort)
        case 40: t.horizontalMargin = try reader.valueAsDouble
        case 63: try t.currentCell().styleOverride.backgroundColor = try color(index: reader.valueAsShort)
        case 64: try t.currentCell().styleOverride.contentColor = try color(index: reader.valueAsShort)
        case 140:
            if let cellTemplate = t.currentCellTemplate { cellTemplate.formatTextHeight = try reader.valueAsDouble }
        case 283: try t.currentCell().styleOverride.isFillColorOn = try reader.valueAsBool
        case 342: t.styleHandle = try reader.valueAsHandle
        case 343: t.blockOwnerHandle = try reader.valueAsHandle
        case 141:
            let row = E.Row()
            row.height = try reader.valueAsDouble
            table.rows.append(row)
        case 142:
            let column = E.Column()
            column.width = try reader.valueAsDouble
            table.columns.append(column)
        case 144:
            _ = try t.currentCell()
            t.currentCellTemplate!.formatTextHeight = try reader.valueAsDouble
        case 145: try t.currentCell().rotation = try reader.valueAsDouble
        case 171: try t.createCell(try reader.valueAsInt)
        case 172: try t.currentCell().edgeFlags = try reader.valueAsShort
        case 173: try t.currentCell().mergedValue = try reader.valueAsShort
        case 174: try t.currentCell().autoFit = try reader.valueAsBool
        case 175: try t.currentCell().borderWidth = try reader.valueAsInt
        case 176: try t.currentCell().borderHeight = try reader.valueAsInt
        case 178: try t.currentCell().virtualEdgeFlag = try reader.valueAsShort
        case 301:
            let content = E.CellContent()
            try t.currentCell().contents.append(content)
            _ = try readCadValue(content.cadValue)
        case 340:
            _ = try t.currentCell()
            t.currentCellTemplate!.valueHandle = try reader.valueAsHandle
        default:
            if mapped({ try assignInsert(table) }) { return true }
            return mapped {
                switch reader.code {
                case 11, 21, 31: table.horizontalDirection[axis(reader.code)] = try reader.valueAsDouble
                case 94: table.overrideBorderColor = try reader.valueAsBool
                case 95: table.overrideBorderLineWeight = try reader.valueAsBool
                case 96: table.overrideBorderVisibility = try reader.valueAsBool
                case 93: table.overrideFlag = try reader.valueAsBool
                case 90: table.valueFlag = try reader.valueAsInt
                case 280: table.version = try reader.valueAsShort
                case 91, 92: break
                default: return false
                }
                return true
            }
        }
        return true
    }

    /// Cell text: a first value, or appended to the existing string (`Value as string` + text).
    private func appendText(_ value: ACad.CadValue, _ text: String) throws {
        if value.value == nil {
            try value.setValue(.string(text), type: ACad.CadValueType.string)
        } else {
            var current = ""
            if case let .string(s)? = value.value { current = s }
            try value.setValue(.string(current + text), type: ACad.CadValueType.string)
        }
    }

    // ───────────────────────── TABLESTYLE ─────────────────────────

    /// `readTableStyle`: cell style values go to the current cell style (a null reference before the first 7).
    func readTableStyle(_ t: ACad.CadTableStyleTemplate) throws -> Bool {
        let style = t.cadObject as! ACad.TableStyle
        func cell() throws -> ACad.TableStyle.CellStyle {
            guard let template = t.currentCellStyleTemplate else {
                throw ACad.DxfException("Object reference not set to an instance of an object.")
            }
            return template.cellStyle
        }
        switch reader.code {
        case 7:
            t.createCurrentCellStyleTemplate().textStyleName = reader.valueAsString
        case 94: try cell().alignment = try reader.valueAsInt
        case 62: try cell().color = try color(index: reader.valueAsShort)
        case 63: try cell().backgroundColor = try color(index: reader.valueAsShort)
        case 140: try cell().textHeight = try reader.valueAsDouble
        case 170: try cell().cellAlignment = Int32(try reader.valueAsShort)
        case 283: try cell().isFillColorOn = try reader.valueAsBool
        case 90: try cell().type = Int32(try reader.valueAsShort)
        case 91: try cell().styleClass = Int32(try reader.valueAsShort)
        case 1: break
        case 274: try cell().topBorder.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
        case 275: try cell().horizontalInsideBorder.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
        case 276: try cell().bottomBorder.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
        case 277: try cell().leftBorder.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
        case 278: try cell().verticalInsideBorder.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
        case 279: try cell().rightBorder.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
        case 284: try cell().topBorder.isInvisible = try reader.valueAsBool
        case 285: try cell().horizontalInsideBorder.isInvisible = try reader.valueAsBool
        case 286: try cell().bottomBorder.isInvisible = try reader.valueAsBool
        case 287: try cell().leftBorder.isInvisible = try reader.valueAsBool
        case 288: try cell().verticalInsideBorder.isInvisible = try reader.valueAsBool
        case 289: try cell().rightBorder.isInvisible = try reader.valueAsBool
        case 64: try cell().topBorder.color = try color(index: reader.valueAsShort)
        case 65: try cell().horizontalInsideBorder.color = try color(index: reader.valueAsShort)
        case 66: try cell().bottomBorder.color = try color(index: reader.valueAsShort)
        case 67: try cell().leftBorder.color = try color(index: reader.valueAsShort)
        case 68: try cell().verticalInsideBorder.color = try color(index: reader.valueAsShort)
        case 69: try cell().rightBorder.color = try color(index: reader.valueAsShort)
        default:
            return mapped {
                switch reader.code {
                case 3: style.description = rawString
                case 71: style.flags = try reader.valueAsShort
                case 70: style.flowDirection = try reader.valueAsShort
                case 40: style.horizontalCellMargin = try reader.valueAsDouble
                case 281: style.suppressHeaderRow = try reader.valueAsBool
                case 280: style.suppressTitle = try reader.valueAsBool
                case 41: style.verticalCellMargin = try reader.valueAsDouble
                default: return false
                }
                return true
            }
        }
        return true
    }

    // ───────────────────────── TABLECONTENT ─────────────────────────

    private func isValue(_ text: String) -> Bool { reader.valueAsString.caseInsensitiveCompare(text) == .orderedSame }

    /// `readTableContent`: the subclass readers stop at the next subclass marker or object.
    func readTableContent(_ t: ACad.CadTableContentTemplate) throws -> Bool {
        typealias M = ACad.DxfSubclassMarker
        guard reader.code == 100 else { return false }
        if isValue(M.tableContent) {
            try readTableContentSubclass(t)
        } else if isValue(M.formattedTableData) {
            try readFormattedTableDataSubclass(t)
        } else if isValue(M.linkedTableData) {
            try readLinkedTableDataSubclass()
        } else if isValue(M.linkedData) {
            try readLinkedData(t)
        } else {
            return false
        }
        lockPointer = true
        return true
    }

    private func readTableContentSubclass(_ t: ACad.CadTableContentTemplate) throws {
        try reader.readNext()
        while reader.code != 0, reader.code != 100 {
            if reader.code == 340 {
                t.styleHandle = try reader.valueAsHandle
            } else {
                notifyUnhandled("readTableContentSubclass")
            }
            try reader.readNext()
        }
    }

    private func readFormattedTableDataSubclass(_ t: ACad.CadTableContentTemplate) throws {
        let table = t.cadObject as! ACad.TableContent
        try reader.readNext()
        var range: ACad.TableEntity.CellRange?
        func current() -> ACad.TableEntity.CellRange {
            if let range { return range }
            let created = ACad.TableEntity.CellRange()
            table.mergedCellRanges.append(created)
            range = created
            return created
        }
        while reader.code != 0, reader.code != 100 {
            switch reader.code {
            case 90: break
            case 91: current().topRowIndex = try reader.valueAsInt
            case 92: current().leftColumnIndex = try reader.valueAsInt
            case 93: current().bottomRowIndex = try reader.valueAsInt
            case 94:
                current().rightColumnIndex = try reader.valueAsInt
                range = nil
            case 300 where isValue("TABLEFORMAT"):
                try readStyleOverride(ACad.CadCellStyleTemplate(table.cellStyleOverride))
            default:
                notifyUnhandled("readFormattedTableDataSubclass")
            }
            try reader.readNext()
        }
    }

    private func readLinkedTableDataSubclass() throws {
        try reader.readNext()
        while reader.code != 0, reader.code != 100 {
            switch reader.code {
            case 90, 91, 92: break
            case 300 where isValue(ACad.DxfFileToken.objectTableColumn): try readTableColumn()
            case 301 where isValue(ACad.DxfFileToken.objectTableRow): try readTableRow()
            default: notifyUnhandled("readLinkedTableDataSubclass")
            }
            try reader.readNext()
        }
    }

    private func readLinkedData(_ t: ACad.CadTableContentTemplate) throws {
        let data = t.cadObject as! ACad.LinkedData
        try reader.readNext()
        while reader.code != 0, reader.code != 100 {
            let assigned = mapped {
                switch reader.code {
                case 1: data.name = rawString
                case 300: data.description = rawString
                default: return false
                }
                return true
            }
            if !assigned { notifyUnhandled("readLinkedData") }
            try reader.readNext()
        }
    }

    /// `readTableColumn()`: the column is parsed and dropped like in ACadSharp.
    private func readTableColumn() throws {
        try reader.readNext()
        let column = ACad.TableEntity.Column()
        while reader.code != 0 {
            if reader.code == 1, isValue(ACad.DxfFileToken.linkedTableDataColumn_BEGIN) {
                try readLinkedTableColumn(column)
            } else if reader.code == 1, isValue(ACad.DxfFileToken.formattedTableDataColumn_BEGIN) {
                try readFormattedTableColumn(column)
            } else if reader.code == 1, isValue(ACad.DxfFileToken.objectTableColumnBegin) {
                try readTableColumnValues(column)
                return
            } else {
                notifyUnhandled("readTableColumn")
            }
            try reader.readNext()
        }
    }

    private func readTableColumnValues(_ column: ACad.TableEntity.Column) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue("TABLECOLUMN_BEGIN"): break
            case 1: end = true
            case 40: column.width = try reader.valueAsDouble
            case 90: break
            case 309: end = isValue("TABLECOLUMN_END")
            default: notifyUnhandled("readTableColumn")
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readLinkedTableColumn(_ column: ACad.TableEntity.Column) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue(ACad.DxfFileToken.linkedTableDataColumn_BEGIN): break
            case 1: end = true
            case 91: column.customData = try reader.valueAsInt
            case 300: column.name = reader.valueAsString
            case 301 where isValue(ACad.DxfFileToken.customData): try readCustomData()
            case 309: end = isValue(ACad.DxfFileToken.linkedTableDataColumn_END)
            default: notifyUnhandled("readLinkedTableColumn")
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readFormattedTableColumn(_ column: ACad.TableEntity.Column) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 300 where isValue("COLUMNTABLEFORMAT"): break
            case 1 where isValue("TABLEFORMAT_BEGIN"): try readStyleOverride(ACad.CadCellStyleTemplate(column.cellStyleOverride))
            case 309: end = isValue(ACad.DxfFileToken.formattedTableDataColumn_END)
            default: notifyUnhandled("readFormattedTableColumn")
            }
            if end { break }
            try reader.readNext()
        }
    }

    /// `readTableRow()`: parsed and dropped.
    private func readTableRow() throws {
        try reader.readNext()
        let row = ACad.TableEntity.Row()
        while reader.code != 0 {
            if reader.code == 1, isValue(ACad.DxfFileToken.linkedTableDataRow_BEGIN) {
                try readLinkedTableRow(row)
            } else if reader.code == 1, isValue(ACad.DxfFileToken.formattedTableDataRow_BEGIN) {
                try readFormattedTableRow(row)
            } else if reader.code == 1, isValue(ACad.DxfFileToken.objectTableRowBegin) {
                try readTableRowValues(row)
                return
            } else {
                notifyUnhandled("readTableRow")
            }
            try reader.readNext()
        }
    }

    private func readTableRowValues(_ row: ACad.TableEntity.Row) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 40: row.height = try reader.valueAsDouble
            case 90: break
            case 309: end = isValue("TABLEROW_END")
            default: notifyUnhandled("readTableRow")
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readLinkedTableRow(_ row: ACad.TableEntity.Row) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue(ACad.DxfFileToken.linkedTableDataRow_BEGIN): break
            case 90: break
            case 91: row.customData = try reader.valueAsInt
            case 300 where isValue(ACad.DxfFileToken.objectCell): try readCell()
            case 301 where isValue(ACad.DxfFileToken.customData): try readCustomData()
            case 309: end = isValue(ACad.DxfFileToken.linkedTableDataRow_END)
            default: notifyUnhandled("readLinkedTableRow")
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readFormattedTableRow(_ row: ACad.TableEntity.Row) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 300 where isValue("ROWTABLEFORMAT"): break
            case 1 where isValue("TABLEFORMAT_BEGIN"): try readStyleOverride(ACad.CadCellStyleTemplate(row.cellStyleOverride))
            case 309: end = isValue("FORMATTEDTABLEDATAROW_END")
            default: notifyUnhandled("readFormattedTableRow")
            }
            if end { break }
            try reader.readNext()
        }
    }

    /// `readCell`.
    private func readCell() throws {
        try reader.readNext()
        let cell = ACad.TableEntity.Cell()
        while reader.code != 0 {
            if reader.code == 1, isValue("LINKEDTABLEDATACELL_BEGIN") {
                try readLinkedTableCell(cell)
            } else if reader.code == 1, isValue("FORMATTEDTABLEDATACELL_BEGIN") {
                try readFormattedTableCell(cell)
            } else if reader.code == 1, isValue("TABLECELL_BEGIN") {
                try readTableCell(cell)
                return
            } else {
                notifyUnhandled("readCell")
            }
            try reader.readNext()
        }
    }

    private func readLinkedTableCell(_ cell: ACad.TableEntity.Cell) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 95: break
            case 301 where isValue(ACad.DxfFileToken.customData): try readCustomData()
            case 302 where isValue("CONTENT"): try readLinkedTableCellContent()
            case 309: end = isValue("LINKEDTABLEDATACELL_END")
            default: if !mapped({ try assignCell(cell) }) { notifyUnhandled("readLinkedTableCell") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readFormattedTableCell(_ cell: ACad.TableEntity.Cell) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 300 where isValue("CELLTABLEFORMAT"):
                try readCellTableFormat(cell)
                continue
            case 309: end = isValue("FORMATTEDTABLEDATACELL_END")
            default: if !mapped({ try assignCell(cell) }) { notifyUnhandled("readFormattedTableCell") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readTableCell(_ cell: ACad.TableEntity.Cell) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 40, 41, 330: break
            case 309: end = isValue("TABLECELL_END")
            default: if !mapped({ try assignCell(cell) }) { notifyUnhandled("readTableCell") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    /// The `Cell` class map: integer properties only take values of their own width.
    private func assignCell(_ cell: ACad.TableEntity.Cell) throws -> Bool {
        switch reader.code {
        case 174: cell.autoFit = try reader.valueAsBool
        case 144: cell.blockScale = try reader.valueAsDouble
        case 175, 176: throw ACad.DxfException("Object of type 'System.Int16' cannot be converted to type 'System.Int32'.")
        case 91: cell.customData = try reader.valueAsInt
        case 172: cell.edgeFlags = try reader.valueAsShort
        case 92: cell.hasLinkedData = try reader.valueAsBool
        case 173: cell.mergedValue = try reader.valueAsShort
        case 145: cell.rotation = try reader.valueAsDouble
        case 90: cell.stateFlags = try reader.valueAsInt
        case 300: cell.toolTip = rawString
        case 171: cell.type = Int32(try reader.valueAsShort)
        case 178: cell.virtualEdgeFlag = try reader.valueAsShort
        default: return false
        }
        return true
    }

    /// `readCellTableFormat`: runs while the current group is a code 1.
    private func readCellTableFormat(_ cell: ACad.TableEntity.Cell) throws {
        try reader.readNext()
        while reader.code == 1 {
            if isValue("TABLEFORMAT_BEGIN") {
                try readStyleOverride(ACad.CadCellStyleTemplate(cell.styleOverride))
            } else if isValue("CELLSTYLE_BEGIN") {
                try readCellStyle()
            } else {
                notifyUnhandled("readCellTableFormat")
            }
            try reader.readNext()
        }
    }

    /// `readCellStyle`: runs until a code 1 or CELLSTYLE_END, across object boundaries.
    private func readCellStyle() throws {
        try reader.readNext()
        while reader.code != 1 {
            if reader.code == 309, isValue("CELLSTYLE_END") { break }
            if reader.code != 309 { notifyUnhandled("readCellStyle") }
            try reader.readNext()
        }
    }

    private func readLinkedTableCellContent() throws {
        let content = ACad.TableEntity.CellContent()
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue("FORMATTEDCELLCONTENT_BEGIN"):
                try readFormattedCellContent()
                end = true
            case 1 where isValue("CELLCONTENT_BEGIN"):
                try readCellContent(content)
            default:
                let assigned = mapped {
                    guard reader.code == 90 else { return false }
                    content.contentType = try reader.valueAsInt
                    return true
                }
                if !assigned { notifyUnhandled("readLinkedTableCellContent") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readCellContent(_ content: ACad.TableEntity.CellContent) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 91, 340: break
            case 300 where isValue("VALUE"): _ = try readCadValue(content.cadValue)
            case 309: end = isValue("CELLCONTENT_END")
            default:
                let assigned = mapped {
                    guard reader.code == 90 else { return false }
                    content.contentType = try reader.valueAsInt
                    return true
                }
                if !assigned { notifyUnhandled("readCellContent") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readFormattedCellContent() throws {
        let template = ACad.CellContentFormatTemplate(ACad.TableStyle.ContentFormat())
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 300 where isValue("CONTENTFORMAT"): try readContentFormat(template)
            case 309: end = isValue("FORMATTEDCELLCONTENT_END")
            default: if !mapped({ try assignContentFormat(template.format) }) { notifyUnhandled("readFormattedCellContent") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readContentFormat(_ template: ACad.CellContentFormatTemplate) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue("CONTENTFORMAT_BEGIN"): break
            case 309: end = isValue("CONTENTFORMAT_END")
            case 340: template.textStyleHandle = try reader.valueAsHandle
            default: if !mapped({ try assignContentFormat(template.format) }) { notifyUnhandled("readContentFormat") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    /// The `ContentFormat` class map.
    private func assignContentFormat(_ format: ACad.TableStyle.ContentFormat) throws -> Bool {
        switch reader.code {
        case 94: format.alignment = try reader.valueAsInt
        case 62: format.color = try color(index: reader.valueAsShort)
        case 170: format.hasData = try reader.valueAsBool
        case 90: format.propertyFlags = try reader.valueAsInt
        case 91: format.propertyOverrideFlags = try reader.valueAsInt
        case 40: format.rotation = try reader.valueAsAngle
        case 144: format.scale = try reader.valueAsDouble
        case 140: format.textHeight = try reader.valueAsDouble
        case 7: return false
        case 92: format.valueDataType = try reader.valueAsInt
        case 300: format.valueFormatString = rawString
        case 93: format.valueUnitType = try reader.valueAsInt
        default: return false
        }
        return true
    }

    /// The `CellStyle` class map (declared members only). ACadSharp 3.8 converts colours only for codes 62, 90 and
    /// 420, so the 63 / 64 colours count as read but stay unchanged.
    private func assignCellStyleMap(_ style: ACad.TableStyle.CellStyle) throws -> Bool {
        switch reader.code {
        case 63, 64: break
        case 170: style.cellAlignment = Int32(try reader.valueAsShort)
        case 283: style.isFillColorOn = try reader.valueAsBool
        case 171: style.marginOverrideFlags = Int32(try reader.valueAsShort)
        case 300: style.name = rawString
        case 91: style.styleClass = try reader.valueAsInt
        case 92: style.tableCellStylePropertyFlags = try reader.valueAsInt
        case 62: style.textColor = try color(index: reader.valueAsShort)
        case 90: style.type = try reader.valueAsInt
        default: return false
        }
        return true
    }

    /// `readStyleOverride`.
    private func readStyleOverride(_ template: ACad.CadCellStyleTemplate) throws {
        let style = template.cellStyle
        try reader.readNext()
        var border = ACad.TableStyle.CellEdgeFlags.unknown
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 95: border = try reader.valueAsInt
            case 1 where isValue("TABLEFORMAT_BEGIN"): break
            case 300 where isValue("CONTENTFORMAT"):
                try readContentFormat(ACad.CellContentFormatTemplate(ACad.TableStyle.ContentFormat()))
            case 301 where isValue("MARGIN"): try readCellMargin(style)
            case 302 where isValue("GRIDFORMAT"): try readGridFormat(template, ACad.TableStyle.CellBorder(border))
            case 309: end = isValue("TABLEFORMAT_END")
            default:
                if !mapped({ try assignCellStyleMap(style) }), !mapped({ try assignContentFormat(style) }) {
                    notifyUnhandled("readStyleOverride")
                }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readCellMargin(_ style: ACad.TableStyle.CellStyle) throws {
        try reader.readNext()
        var i = 0
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue("CELLMARGIN_BEGIN"): break
            case 40:
                let value = try reader.valueAsDouble
                switch i {
                case 0: style.verticalMargin = value
                case 1: style.horizontalMargin = value
                case 2: style.bottomMargin = value
                case 3: style.rightMargin = value
                case 4: style.marginHorizontalSpacing = value
                case 5: style.marginVerticalSpacing = value
                default: break
                }
                i += 1
            case 309: end = isValue("CELLMARGIN_END")
            default: notifyUnhandled("readCellMargin")
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readGridFormat(_ template: ACad.CadCellStyleTemplate, _ border: ACad.TableStyle.CellBorder) throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue("GRIDFORMAT_BEGIN"): break
            case 62: border.color = try color(index: reader.valueAsShort)
            case 92: border.lineWeight = ACad.LineWeight(rawValue: Int16(truncatingIfNeeded: try reader.valueAsInt))
            case 93: border.isInvisible = try reader.valueAsBool
            case 340: template.borderLineTypePairs.append((border, try reader.valueAsHandle))
            case 309: end = isValue("GRIDFORMAT_END")
            default:
                let assigned = mapped {
                    switch reader.code {
                    case 64: break
                    case 40: border.doubleLineSpacing = try reader.valueAsDouble
                    case 95: throw ACad.DxfException("Property set method not found.")
                    case 284: border.isInvisible = try reader.valueAsBool
                    case 274: border.lineWeight = ACad.LineWeight(rawValue: try reader.valueAsShort)
                    case 90: border.propertyOverrideFlags = try reader.valueAsInt
                    case 91: border.type = Int16(truncatingIfNeeded: try reader.valueAsInt)
                    default: return false
                    }
                    return true
                }
                if !assigned { notifyUnhandled("readGridFormat") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    /// `readCustomData`.
    private func readCustomData() throws {
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 1 where isValue("DATAMAP_BEGIN"): break
            case 90, 300: break
            case 301 where isValue("DATAMAP_VALUE"): try readDataMapValue()
            case 309: end = isValue("DATAMAP_END")
            default: notifyUnhandled("readCustomData")
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func readDataMapValue() throws {
        let value = ACad.CadValue()
        try reader.readNext()
        while reader.code != 0 {
            var end = false
            switch reader.code {
            case 11, 21, 31, 91, 92, 140, 310: break
            case 304: end = isValue(ACad.DxfFileToken.valueEnd)
            default:
                let assigned = mapped {
                    switch reader.code {
                    case 93: value.flags = try reader.valueAsInt
                    case 300: value.format = rawString
                    case 302: value.formattedValue = rawString
                    case 94: value.units = try reader.valueAsInt
                    case 90: value.valueType = try reader.valueAsInt
                    default: return false
                    }
                    return true
                }
                if !assigned { notifyUnhandled("readDataMapValue") }
            }
            if end { break }
            try reader.readNext()
        }
    }

    private func notifyUnhandled(_ method: String) {
        builder.notify("Unhandled dxf code \(reader.code) value \(reader.valueAsString) at \(method) method.")
    }
}
