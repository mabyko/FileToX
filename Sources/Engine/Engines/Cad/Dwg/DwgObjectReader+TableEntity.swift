// ACadSharp 3.8.0 DwgObjectReader (DwgObjectReader.Entities.cs and readTableStyle): ACAD_TABLE entities in the R2010+
// layout (table content, cells with contents and style overrides, break data) and the R2007- layout (cell data and
// table/border overrides), table styles, and the typed values (`CadValue`) of cells and fields.

import Foundation

fileprivate typealias A = ACad

extension ACad.DwgObjectReader {
    // ───────────────────────── Table entity ─────────────────────────

    func readTableEntity() throws -> ACad.CadTemplate? {
        let table = A.TableEntity()
        let template = A.CadTableEntityTemplate(table)

        try readInsertCommonData(template)
        try readInsertCommonHandles(template)

        if r2010Plus {
            // RC Unknown (default 0)
            _ = try mergedReaders.readByte()
            // H Unknown (soft pointer, default NULL)
            template.nullHandle = try handleReference()
            // BL Unknown (default 0)
            _ = try mergedReaders.readBitLong()
            if r2013Plus {
                // Unknown (default 0)
                _ = try mergedReaders.readBitLong()
            } else {
                // R2010: B Unknown (default true)
                _ = try mergedReaders.readBit()
            }

            // The table content (see TABLECONTENT object) without the common OBJECT data.
            try readTableContent(table.content, template)

            // BS Unknown (default 38)
            _ = try mergedReaders.readBitShort()
            // 3BD 11 Horizontal direction
            table.horizontalDirection = try mergedReaders.read3BitDouble()

            // BL Has break data flag (0 = no break data, 1 = has break data)
            table.hasBreadData = try mergedReaders.readBitLong() == 1
            if table.hasBreadData {
                let breakData = table.breakData
                // BL Option flags
                breakData.flags = try mergedReaders.readBitLong()
                // BL Flow direction
                breakData.flowDirection = try mergedReaders.readBitLong()
                // BD Break spacing
                breakData.breakSpacing = try mergedReaders.readBitDouble()
                // BL Unknown flags
                _ = try mergedReaders.readBitLong()
                // BL Unknown flags
                _ = try mergedReaders.readBitLong()
                // BL Number of manual positions (break heights)
                let num = try mergedReaders.readBitLong()
                var i: Int32 = 0
                while i < num {
                    var breakHeight = A.TableEntity.TableBreakData.BreakHeight()
                    // 3BD Position
                    breakHeight.position = try mergedReaders.read3BitDouble()
                    // BD Height
                    breakHeight.height = try mergedReaders.readBitDouble()
                    // BL Flags (meaning unknown)
                    _ = try mergedReaders.readBitLong()
                    breakData.heights.append(breakHeight)
                    i += 1
                }
            }

            // BL Number of break row ranges (there is always at least 1)
            let rowRanges = try mergedReaders.readBitLong()
            var i: Int32 = 0
            while i < rowRanges {
                let breakRowRange = A.TableEntity.BreakRowRange()
                // 3BD Position
                breakRowRange.position = try mergedReaders.read3BitDouble()
                // BL Start row index
                breakRowRange.startRowIndex = try mergedReaders.readBitLong()
                // BL End row index
                breakRowRange.endRowIndex = try mergedReaders.readBitLong()
                table.breakRowRanges.append(breakRowRange)
                i += 1
            }

            return template
        }

        // Until R2007
        // Flag for table value BS 90
        table.valueFlag = Int32(try mergedReaders.readBitShort())
        // Hor.Dir.Vector 3BD 11
        table.horizontalDirection = try mergedReaders.read3BitDouble()
        // Number of columns BL 92
        let ncols = try mergedReaders.readBitLong()
        // Number of rows BL 91
        let nrows = try mergedReaders.readBitLong()

        // Column widths BD 142
        var c: Int32 = 0
        while c < ncols {
            let column = A.TableEntity.Column()
            column.width = try mergedReaders.readBitDouble()
            table.columns.append(column)
            c += 1
        }
        // Row heights BD 141
        var r: Int32 = 0
        while r < nrows {
            let row = A.TableEntity.Row()
            row.height = try mergedReaders.readBitDouble()
            table.rows.append(row)
            r += 1
        }

        // H 342 Table Style ID (hard pointer)
        template.styleHandle = try handleReference()

        for row in table.rows {
            for _ in table.columns {
                // Cell data, repeats for all cells in n x m table
                let cell = A.TableEntity.Cell()
                row.cells.append(cell)
                let cellTemplate = A.CadTableCellTemplate(cell)
                template.cellTemplates.append(cellTemplate)
                try readTableCellData(cellTemplate)
            }
        }

        // Has table overrides B
        if try mergedReaders.readBit() {
            let styleOverride = A.TableStyle()
            table.content.styleOverride = styleOverride
            // Cell flag override BL 177 (deprecated); the values are read in flag order and dropped.
            let flags = try mergedReaders.readBitLong()
            // Title suppressed B 280
            if flags & 0x1 != 0 { styleOverride.suppressTitle = try mergedReaders.readBit() }
            // (Header suppressed 0x2 has no data.) Flow direction BS 70
            if flags & 0x4 != 0 { _ = try mergedReaders.readBitShort() }
            // Horz. / vert. cell margin BD 40, 41
            if flags & 0x8 != 0 { _ = try mergedReaders.readBitDouble() }
            if flags & 0x10 != 0 { _ = try mergedReaders.readBitDouble() }
            // Title / header / data row color CMC 64
            for bit in [0x20, 0x40, 0x80] as [Int32] where flags & bit != 0 { _ = try mergedReaders.readCmColor(useTextStream: r2004Pre) }
            // Title / header / data row fill none B 283
            for bit in [0x100, 0x200, 0x400] as [Int32] where flags & bit != 0 { _ = try mergedReaders.readBit() }
            // Title / header / data row fill color CMC 63
            for bit in [0x800, 0x1000, 0x2000] as [Int32] where flags & bit != 0 { _ = try mergedReaders.readCmColor(useTextStream: r2004Pre) }
            // Title / header / data row alignment BS 170
            for bit in [0x4000, 0x8000, 0x10000] as [Int32] where flags & bit != 0 { _ = try mergedReaders.readBitShort() }
            // Title / header / data text style H 7
            for bit in [0x20000, 0x40000, 0x80000] as [Int32] where flags & bit != 0 { _ = try handleReference() }
            // Title / header / data row height BD 140
            for bit in [0x100000, 0x200000, 0x400000] as [Int32] where flags & bit != 0 { _ = try mergedReaders.readBitDouble() }
        }

        // Has border color overrides B: BL 94 flags, then one CMC per set bit (title, header, data borders)
        if try mergedReaders.readBit() {
            let flags = try mergedReaders.readBitLong()
            for bit in 0..<18 where flags & (Int32(1) << bit) != 0 { _ = try mergedReaders.readCmColor(useTextStream: r2004Pre) }
        }
        // Has border lineweight overrides B: BL 95 flags, then one BS per set bit
        if try mergedReaders.readBit() {
            let flags = try mergedReaders.readBitLong()
            for bit in 0..<18 where flags & (Int32(1) << bit) != 0 { _ = try mergedReaders.readBitShort() }
        }
        // Has border visibility overrides B: BL 96 flags, then one BS per set bit
        if try mergedReaders.readBit() {
            let flags = try mergedReaders.readBitLong()
            for bit in 0..<18 where flags & (Int32(1) << bit) != 0 { _ = try mergedReaders.readBitShortAsBool() }
        }

        return template
    }

    private func readTableContent(_ content: ACad.TableContent, _ template: ACad.CadTableEntityTemplate) throws {
        let tableEntity = template.cadObject as! A.TableEntity

        // TV 1 Name
        content.name = try mergedReaders.readVariableText()
        // TV 300 Description AcDbLinkedTableData fields
        content.description = try mergedReaders.readVariableText()

        // BL 90 Number of columns
        let cols = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < cols {
            let column = A.TableEntity.Column()
            let columnTemplate = A.CadTableComponentTemplate(column)
            tableEntity.columns.append(column)
            template.componentTemplates.append(columnTemplate)

            // TV 300 Column name
            column.name = try mergedReaders.readVariableText()
            // BL 91 32 bit integer containing custom data
            column.customData = try mergedReaders.readBitLong()
            // BL 90 Number of custom data items
            let dataItems = try mergedReaders.readBitLong()
            var j: Int32 = 0
            while j < dataItems {
                let entry = A.TableEntity.CustomDataEntry()
                try readCustomTableData(entry)
                column.customDataCollection.append(entry)
                j += 1
            }
            // Cell style data: the cell style overrides of the column
            let styleTemplate = A.CadCellStyleTemplate(column.cellStyleOverride)
            columnTemplate.cellStyleTemplate = styleTemplate
            try readCellStyle(styleTemplate)
            // BL 90 Cell style ID
            columnTemplate.styleId = try mergedReaders.readBitLong()
            // BD 40 Column width.
            column.width = try mergedReaders.readBitDouble()
            i += 1
        }

        // BL 91 Number of rows.
        let nrows = try mergedReaders.readBitLong()
        var r: Int32 = 0
        while r < nrows {
            let row = A.TableEntity.Row()
            let rowTemplate = A.CadTableComponentTemplate(row)
            tableEntity.rows.append(row)
            template.componentTemplates.append(rowTemplate)

            // BL 90 Number of cells in row.
            let ncells = try mergedReaders.readBitLong()
            var j: Int32 = 0
            while j < ncells {
                let cell = A.TableEntity.Cell()
                let cellTemplate = A.CadTableCellTemplate(cell)
                template.cellTemplates.append(cellTemplate)
                try readTableCell(cellTemplate)
                row.cells.append(cell)
                j += 1
            }
            // BL 91 32 bit integer containing custom data
            row.customData = try mergedReaders.readBitLong()
            // BL 90 Number of custom data items
            let dataItems = try mergedReaders.readBitLong()
            var k: Int32 = 0
            while k < dataItems {
                let entry = A.TableEntity.CustomDataEntry()
                try readCustomTableData(entry)
                row.customDataCollection.append(entry)
                k += 1
            }
            // Cell style data: the cell style overrides of the row
            let styleTemplate = A.CadCellStyleTemplate(row.cellStyleOverride)
            rowTemplate.cellStyleTemplate = styleTemplate
            try readCellStyle(styleTemplate)
            // BL 90 Cell style ID
            rowTemplate.styleId = try mergedReaders.readBitLong()
            // 40 Row height
            row.height = try mergedReaders.readBitDouble()
            r += 1
        }

        // BL Number of cell contents that contain a field reference.
        let nfields = try mergedReaders.readBitLong()
        var n: Int32 = 0
        while n < nfields {
            // H Handle to field (AcDbField), hard owner (not queued).
            template.fieldHandles.append(try mergedReaders.handleReference(0))
            n += 1
        }

        // The table's cell style override fields
        let cellStyleTemplate = A.CadCellStyleTemplate(content.cellStyleOverride)
        template.cellStyleTemplate = cellStyleTemplate
        try readCellStyle(cellStyleTemplate)

        // BL 90 Number of merged cell ranges
        let nranges = try mergedReaders.readBitLong()
        var m: Int32 = 0
        while m < nranges {
            let cellRange = A.TableEntity.CellRange()
            // BL 91 Top row index
            cellRange.topRowIndex = try mergedReaders.readBitLong()
            // BL 92 Left column index
            cellRange.leftColumnIndex = try mergedReaders.readBitLong()
            // BL 93 Bottom row index
            cellRange.bottomRowIndex = try mergedReaders.readBitLong()
            // BL 94 Right column index
            cellRange.rightColumnIndex = try mergedReaders.readBitLong()
            content.mergedCellRanges.append(cellRange)
            m += 1
        }

        // H 340 Handle to table style (hard pointer).
        template.styleHandle = try handleReference()
    }

    private func readTableCell(_ template: ACad.CadTableCellTemplate) throws {
        let cell = template.cell

        // BL 90 Cell state flags
        cell.stateFlags = try mergedReaders.readBitLong()
        // TV 300 Tooltip
        cell.toolTip = try mergedReaders.readVariableText()
        // BL 91 32 bit integer containing custom data
        cell.customData = try mergedReaders.readBitLong()
        // Custom data collection
        let ndata = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < ndata {
            let customData = A.TableEntity.CustomDataEntry()
            try readCustomTableData(customData)
            cell.customDataCollection.append(customData)
            i += 1
        }

        // BL 92 Has linked data flags, 0 = false, 1 = true
        cell.hasLinkedData = try mergedReaders.readBitLong() == 1
        if cell.hasLinkedData {
            // H 340 Handle to data link object (hard pointer, not queued).
            template.valueHandle = try mergedReaders.handleReference(0)
            // BL 93 Row count, BL 94 Column count, BL 96 Unknown.
            _ = try mergedReaders.readBitLong()
            _ = try mergedReaders.readBitLong()
            _ = try mergedReaders.readBitLong()
        }

        // BL 95 Number of cell contents
        let cellContents = try mergedReaders.readBitLong()
        var j: Int32 = 0
        while j < cellContents {
            let cellContent = A.TableEntity.CellContent()
            cell.contents.append(cellContent)
            let contentTemplate = A.CadTableCellContentTemplate(cellContent)
            template.contentTemplates.append(contentTemplate)
            try readTableCellContent(contentTemplate)
            j += 1
        }

        let formatTemplate = A.CadCellStyleTemplate(cell.styleOverride)
        try readCellStyle(formatTemplate)

        // BL 90 Cell style ID
        template.styleId = try mergedReaders.readBitLong()

        // BL 91 Unknown flag
        let unknownFlag = try mergedReaders.readBitLong()
        if unknownFlag != 0 {
            // BL 91 Unknown, BD 40 Unknown, BD 40 Unknown
            _ = try mergedReaders.readBitLong()
            _ = try mergedReaders.readBitDouble()
            _ = try mergedReaders.readBitDouble()
            // BL Geometry data flags
            let geomFlags = try mergedReaders.readBitLong()
            // H Unknown
            template.unknownHandle = try handleReference()
            if geomFlags != 0 {
                let geometry = A.TableEntity.CellContentGeometry()
                cell.geometry = geometry
                try readCellContentGeometry(geometry)
            }
        }
    }

    private func readTableCellContent(_ template: ACad.CadTableCellContentTemplate) throws {
        // BL 90 Cell content type
        template.content.contentType = try mergedReaders.readBitLong()
        switch template.content.contentType {
        case A.TableEntity.TableCellContentType.value:
            _ = try readCadValue(template.content.cadValue)
        case A.TableEntity.TableCellContentType.field:
            // H 340 Handle to AcDbField object (hard pointer).
            template.fieldHandle = try handleReference()
        case A.TableEntity.TableCellContentType.block:
            // H 340 Handle to block record (hard pointer).
            template.blockRecordHandle = try handleReference()
        default:
            break
        }

        // BL 91 Number of attributes
        let natts = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < natts {
            let attTemplate = A.CadTableAttributeTemplate()
            // H 330 Handle to attribute definition (ATTDEF), soft pointer.
            attTemplate.attDefHandle = try handleReference()
            // TV 301 Attribute value.
            attTemplate.value = try mergedReaders.readVariableText()
            // BL 92 Index (starts at 1).
            _ = try mergedReaders.readBitLong()
            template.attTemplates.append(attTemplate)
            i += 1
        }

        // BS 170 Has content format overrides flag
        template.content.format.hasData = try mergedReaders.readBitShortAsBool()
        if template.content.format.hasData {
            let formatTemplate = A.CellContentFormatTemplate(template.content.format)
            try readCellContentFormat(formatTemplate, template.content.format)
        }
    }

    /// Cells of R2007- tables.
    private func readTableCellData(_ template: ACad.CadTableCellTemplate) throws {
        let cell = template.cell
        typealias CellType = A.TableEntity.CellType

        // Cell type BS 171 1 = text, 2 = block.
        cell.type = Int32(try mergedReaders.readBitShort())
        // Cell edge flags RC 172
        cell.edgeFlags = Int16(try mergedReaders.readByte())
        // Cell merged value B 173
        cell.mergedValue = try mergedReaders.readBit() ? 1 : 0
        // Autofit flag B 174
        cell.autoFit = try mergedReaders.readBit()
        // Merged width flag BL 175
        cell.borderWidth = try mergedReaders.readBitLong()
        // Merged height flag BL 176
        cell.borderHeight = try mergedReaders.readBitLong()
        // Rotation value BD 145
        cell.rotation = try mergedReaders.readBitDouble()

        // H 344 for text cell, 340 for block cell (hard pointer)
        template.valueHandle = try handleReference()

        if cell.type == CellType.text && template.valueHandle == 0 && version < .ac1021 {
            // Text string TV 1 Present only if 344 value below is 0
            let content = A.TableEntity.CellContent()
            try content.cadValue.setValue(.string(try mergedReaders.readVariableText()), type: A.CadValueType.string)
            cell.contents.append(content)
        } else if cell.type == CellType.block {
            // Block scale BD 144
            cell.blockScale = try mergedReaders.readBitDouble()
            // Has attributes flag B
            if try mergedReaders.readBit() {
                // Attr. Def. count BS 179
                let natts = Int(try mergedReaders.readBitShort())
                var i = 0
                while i < natts {
                    // H 331 Attr. Def. ID (soft pointer)
                    let atthandle = try handleReference()
                    // Attr.Def.index BS Not present in dxf
                    _ = try mergedReaders.readBitShort()
                    // Attr. Def. text TV 300
                    let text = try mergedReaders.readVariableText()
                    if !template.attributeHandles.contains(where: { $0.0 == atthandle && $0.1 == text }) {
                        template.attributeHandles.append((atthandle, text))
                    }
                    i += 1
                }
            }
        }

        // has override flag B
        if try mergedReaders.readBit() {
            // Cell flag override BL 177 (deprecated)
            let flags = try mergedReaders.readBitLong()
            // Virtual edge flag RC 178
            cell.virtualEdgeFlag = Int16(try mergedReaders.readByte())
            let style = cell.styleOverride

            // Cell alignment RS 170
            if flags & 0x01 != 0 { style.cellAlignment = Int32(try mergedReaders.readBitShort()) }
            // Background fill none B 283
            if flags & 0x02 != 0 { style.isFillColorOn = try mergedReaders.readBit() }
            // Background color CMC 63
            if flags & 0x04 != 0 { style.backgroundColor = try mergedReaders.readCmColor(useTextStream: r2004Pre) }
            // Content color CMC 64
            if flags & 0x08 != 0 { style.contentColor = try mergedReaders.readCmColor(useTextStream: r2004Pre) }
            // Text style H 7
            if flags & 0x10 != 0 { template.textStyleOverrideHandle = try handleReference() }
            // Text height BD 140
            if flags & 0x20 != 0 { style.textHeight = try mergedReaders.readBitDouble() }

            // Grid colors (0x40 top, 0x80 right, 0x100 bottom, 0x200 left), line weights (0x400 …) and visibility, whose
            // presence ACadSharp tests with the line weight bits.
            let borders: [(border: A.TableStyle.CellBorder, color: Int32, weight: Int32)] = [
                (style.topBorder, 0x40, 0x400), (style.rightBorder, 0x80, 0x800),
                (style.bottomBorder, 0x100, 0x1000), (style.leftBorder, 0x200, 0x2000),
            ]
            for (border, color, weight) in borders {
                if flags & color != 0 { border.color = try mergedReaders.readCmColor(useTextStream: r2004Pre) }
                if flags & weight != 0 { border.lineWeight = A.LineWeight(try mergedReaders.readBitShort()) }
                if flags & weight != 0 { border.isInvisible = !(try mergedReaders.readBitShortAsBool()) }
            }
        }

        // R2007+:
        if r2007Plus {
            // Unknown BL
            _ = try mergedReaders.readBitLong()
            // Value fields
            cell.contents.append(A.TableEntity.CellContent())
            guard let content = cell.content else {
                throw A.DwgError("Object reference not set to an instance of an object.")
            }
            _ = try readCadValue(content.cadValue)
        }
    }

    private func readCustomTableData(_ entry: ACad.TableEntity.CustomDataEntry) throws {
        // TV 300 Item name
        entry.name = try mergedReaders.readVariableText()
        _ = try readCadValue(entry.value)
    }

    private func readCellContentGeometry(_ geometry: ACad.TableEntity.CellContentGeometry) throws {
        // 3BD Distance to top left
        geometry.distanceTopLeft = try mergedReaders.read3BitDouble()
        // 3BD Distance to center
        geometry.distanceCenter = try mergedReaders.read3BitDouble()
        // BD Content width
        geometry.contentWidth = try mergedReaders.readBitDouble()
        // BD Content height
        geometry.contentHeight = try mergedReaders.readBitDouble()
        // BD Width
        geometry.width = try mergedReaders.readBitDouble()
        // BD Height
        geometry.height = try mergedReaders.readBitDouble()
        // BL Unknown flags
        geometry.flags = try mergedReaders.readBitLong()
    }

    // ───────────────────────── Cell styles ─────────────────────────

    private func readCellStyle(_ template: ACad.CadCellStyleTemplate) throws {
        let cellStyle = template.cellStyle

        // BL 90 Cell style type
        cellStyle.type = try mergedReaders.readBitLong()
        // BS 170 Data flags, 0 = no data, 1 = data is present
        cellStyle.hasData = try mergedReaders.readBitShortAsBool()
        if !cellStyle.hasData { return }

        // BL 91 Property override flags
        cellStyle.propertyOverrideFlags = try mergedReaders.readBitLong()
        // BL 92 Merge flags, but may only for bits 0x8000 and 0x10000.
        cellStyle.tableCellStylePropertyFlags = try mergedReaders.readBitLong()
        // TC 62 Background color
        cellStyle.backgroundColor = try mergedReaders.readCmColor(useTextStream: r2004Pre)
        // BL 93 Content layout flags
        cellStyle.contentLayoutFlags = try mergedReaders.readBitLong()

        // Content format fields
        try readCellContentFormat(template, cellStyle)

        // BS 171 Margin override flags, bit 1 is set if margin overrides are present
        cellStyle.marginOverrideFlags = Int32(try mergedReaders.readBitShort())
        if cellStyle.marginOverrideFlags & 1 != 0 {
            // BD 40 Vertical margin
            cellStyle.verticalMargin = try mergedReaders.readBitDouble()
            // BD 40 Horizontal margin
            cellStyle.horizontalMargin = try mergedReaders.readBitDouble()
            // BD 40 Bottom margin
            cellStyle.bottomMargin = try mergedReaders.readBitDouble()
            // BD 40 Right margin
            cellStyle.rightMargin = try mergedReaders.readBitDouble()
            // BD 40 Margin horizontal spacing
            cellStyle.marginHorizontalSpacing = try mergedReaders.readBitDouble()
            // BD 40 Margin vertical spacing
            cellStyle.marginVerticalSpacing = try mergedReaders.readBitDouble()
        }

        // BL 94 Number of borders present (0-6)
        let nborders = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < nborders {
            i += 1
            // BL 95 Edge flags
            typealias Edge = A.TableStyle.CellEdgeFlags
            switch try mergedReaders.readBitLong() {
            case Edge.top: try readBorder(template, cellStyle.topBorder)
            case Edge.right: try readBorder(template, cellStyle.rightBorder)
            case Edge.bottom: try readBorder(template, cellStyle.bottomBorder)
            case Edge.left: try readBorder(template, cellStyle.leftBorder)
            case Edge.insideVertical: try readBorder(template, cellStyle.verticalInsideBorder)
            case Edge.insideHorizontal: try readBorder(template, cellStyle.horizontalInsideBorder)
            default: continue
            }
        }
    }

    private func readBorder(_ template: ACad.CadCellStyleTemplate, _ border: ACad.TableStyle.CellBorder) throws {
        // BL 90 Border property override flags
        border.propertyOverrideFlags = try mergedReaders.readBitLong()
        // BL 91 Border type (`BorderType : short`)
        border.type = Int16(truncatingIfNeeded: try mergedReaders.readBitLong())
        // TC 62 Color
        border.color = try mergedReaders.readCmColor(useTextStream: r2004Pre)
        // BL 92 Line weight
        border.lineWeight = A.LineWeight(Int16(truncatingIfNeeded: try mergedReaders.readBitLong()))
        // H 40 Line type (hard pointer)
        template.borderLineTypePairs.append((border, try handleReference()))
        // BL 93 Invisibility: 1 = invisible, 0 = visible.
        border.isInvisible = try mergedReaders.readBitLong() == 1
        // BD 40 Double line spacing
        border.doubleLineSpacing = try mergedReaders.readBitDouble()
        border.applyBorder = true
    }

    private func readCellContentFormat(_ template: ACad.CellContentFormatTemplate, _ format: ACad.TableStyle.ContentFormat) throws {
        // BL 90 Property override flags
        format.propertyOverrideFlags = try mergedReaders.readBitLong()
        // BL 91 Property flags. Contains property bit values for property Auto Scale only
        format.propertyFlags = try mergedReaders.readBitLong()
        // BL 92 Value data type
        format.valueDataType = try mergedReaders.readBitLong()
        // BL 93 Value unit type
        format.valueUnitType = try mergedReaders.readBitLong()
        // TV 300 Value format string
        format.valueFormatString = try mergedReaders.readVariableText()
        // BD 40 Rotation
        format.rotation = try mergedReaders.readBitDouble()
        // BD 140 Block scale
        format.scale = try mergedReaders.readBitDouble()
        // BL 94 Cell alignment
        format.alignment = try mergedReaders.readBitLong()
        // TC 62 Content color
        format.color = try mergedReaders.readCmColor(useTextStream: r2004Pre)
        // H 340 Text style handle (hard pointer)
        template.textStyleHandle = try handleReference()
        // BD 144 Text height
        format.textHeight = try mergedReaders.readBitDouble()
    }

    // ───────────────────────── Table style ─────────────────────────

    func readTableStyle() throws -> ACad.CadTemplate? {
        let style = A.TableStyle()
        let template = A.CadTableStyleTemplate(style)

        try readCommonNonEntityData(template)

        if r2007Pre {
            // Description TV 3
            style.description = try mergedReaders.readVariableText()
            // Flow direction BS 70 0 = down, 1 = up
            style.flowDirection = try mergedReaders.readBitShort()
            // Bit flags BS 71 Meaning unknown.
            style.flags = try mergedReaders.readBitShort()
            // Horizontal cell margin BD 40
            style.horizontalCellMargin = try mergedReaders.readBitDouble()
            // Vertical cell margin BD 41
            style.verticalCellMargin = try mergedReaders.readBitDouble()
            // Suppress title B 280
            style.suppressTitle = try mergedReaders.readBit()
            // Suppress header B 281
            style.suppressHeaderRow = try mergedReaders.readBit()
            // Data, title and header row styles in this order
            try readRowCellStyle(template, style.dataCellStyle)
            try readRowCellStyle(template, style.titleCellStyle)
            try readRowCellStyle(template, style.headerCellStyle)
            return template
        }

        // RC - Unknown
        _ = try mergedReaders.readByte()
        // TV 3 Description
        style.description = try mergedReaders.readVariableText()
        // BL - Unknown, BL - Unknown
        _ = try mergedReaders.readBitLong()
        _ = try mergedReaders.readBitLong()
        // H - Unknown (hard owner)
        _ = try handleReference()

        // The cell style with name "Table"
        let tableCellStyleTemplate = A.CadCellStyleTemplate(style.tableCellStyle)
        template.tableCellStyleTemplate = tableCellStyleTemplate
        try readCellStyle(tableCellStyleTemplate)

        // BL 90 Cell style ID, 1 = title, 2 = header, 3 = data, 4 = table (new in R24).
        style.tableCellStyle.id = try mergedReaders.readBitLong()
        // BL 91 Cell style class, 1 = data, 2 = label.
        style.tableCellStyle.styleClass = try mergedReaders.readBitLong()
        // TV 300 Cell style name
        style.tableCellStyle.name = try mergedReaders.readVariableText()

        // BL The number of cell styles (should be 3)
        let nCellStyles = try mergedReaders.readBitLong()
        var i: Int32 = 0
        while i < nCellStyles {
            let cellStyle = A.TableStyle.CellStyle()
            let cellStyleTemplate = A.CadCellStyleTemplate(cellStyle)
            template.cellStyleTemplates.append(cellStyleTemplate)
            // Index starting by 1
            _ = try mergedReaders.readBitLong()
            try readCellStyle(cellStyleTemplate)
            // BL - Cell style ID
            cellStyle.id = try mergedReaders.readBitLong()
            // BL - Cell style class
            cellStyle.styleClass = try mergedReaders.readBitLong()
            // TV - Cell style name
            cellStyle.name = try mergedReaders.readVariableText()
            i += 1
        }
        return template
    }

    private func readRowCellStyle(_ tableStyleTemplate: ACad.CadTableStyleTemplate, _ style: ACad.TableStyle.CellStyle) throws {
        let cellStyleTemplate = A.CadCellStyleTemplate(style)
        tableStyleTemplate.cellStyleTemplates.append(cellStyleTemplate)

        // Text style ID H 7 Hard pointer.
        cellStyleTemplate.textStyleHandle = try handleReference()
        // Text height BD 140
        style.textHeight = try mergedReaders.readBitDouble()
        // Text alignment BS 170
        style.cellAlignment = Int32(try mergedReaders.readBitShort())
        // Text color CMC 62
        style.textColor = try mergedReaders.readCmColor(useTextStream: r2004Pre)
        // Fill color CMC 63
        style.backgroundColor = try mergedReaders.readCmColor(useTextStream: r2004Pre)
        // Background color enabled B 283
        style.isFillColorOn = try mergedReaders.readBit()

        // 6 borders: top, horizontal inside, bottom, left, vertical inside, right
        try readBorderStyle(style.topBorder)
        try readBorderStyle(style.horizontalInsideBorder)
        try readBorderStyle(style.bottomBorder)
        try readBorderStyle(style.leftBorder)
        try readBorderStyle(style.verticalInsideBorder)
        try readBorderStyle(style.rightBorder)

        if r2007Plus {
            // Data type BL 90
            style.valueDataType = try mergedReaders.readBitLong()
            // Data unit type BL 91
            style.valueUnitType = try mergedReaders.readBitLong()
            // Format string TV 1
            style.valueFormatString = try mergedReaders.readVariableText()
        }
    }

    private func readBorderStyle(_ border: ACad.TableStyle.CellBorder) throws {
        // Line weight BS 274-279
        border.lineWeight = A.LineWeight(try mergedReaders.readBitShort())
        // Visible B 284-289 0 = invisible, 1 = visible
        border.isInvisible = !(try mergedReaders.readBit())
        // Border color CMC 64-69
        border.color = try mergedReaders.readCmColor(useTextStream: r2004Pre)
    }

    // ───────────────────────── Typed values ─────────────────────────

    /// `readDateCadValue`: nil for sizes ACadSharp does not decode.
    func readDateCadValue() throws -> Date? {
        // data size N, followed by N bytes
        let size = try mergedReaders.readBitLong()
        if size <= 0 { return nil }
        let array = try mergedReaders.readBytes(Int(size))
        func int16(_ offset: Int) -> Int { Int(Int16(bitPattern: UInt16(array[offset]) | UInt16(array[offset + 1]) << 8)) }

        let dateTime: A.CadDateTime?
        if r2007Plus {
            switch size {
            case 16:
                dateTime = A.CadDateTime(int16(0), int16(2), int16(6), int16(8), int16(10), int16(12), int16(14))
            case 14:
                dateTime = A.CadDateTime(int16(0), int16(2), int16(4), int16(6), int16(8), int16(10), int16(12))
            default:
                return nil
            }
        } else {
            if size != 8 { return nil }
            func int32BigEndian(_ offset: Int) -> Int64 {
                Int64(Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(array[offset + $1]) }))
            }
            let seconds = int32BigEndian(0) << 32 | (int32BigEndian(4) & 0xFFFF_FFFF)
            dateTime = A.CadDateTime(1970, 1, 1)!.adding(seconds: Double(seconds))
        }
        // `new DateTime(...)` / `AddSeconds` throw outside the DateTime range.
        guard let dateTime else {
            throw A.DwgError("Year, Month, and Day parameters describe an un-representable DateTime.")
        }
        let epoch = A.CadDateTime(1970, 1, 1)!
        return Date(timeIntervalSince1970: Double(dateTime.ticks - epoch.ticks) / 10_000_000)
    }

    /// `readStringCadValue`: a byte count and the bytes (UTF-16 without its terminator from R2007).
    func readStringCadValue() throws -> String {
        let length = try mergedReaders.readBitLong()
        let bytes = try mergedReaders.readBytes(Int(length))
        if r2007Plus {
            guard length >= 2 else {
                throw A.DwgError("Non-negative number required. (Parameter 'count')")
            }
            // `Encoding.Unicode.GetString(arr, 0, length - 2)`: a trailing odd byte decodes as U+FFFD.
            let text = bytes.prefix(Int(length) - 2)
            var units: [UInt16] = []
            var i = text.startIndex
            while i + 1 < text.endIndex {
                units.append(UInt16(text[i]) | UInt16(text[i + 1]) << 8)
                i += 2
            }
            if text.count % 2 == 1 { units.append(0xFFFD) }
            return String(decoding: units, as: UTF16.self)
        }
        return A.DwgText.decode(bytes, mergedReaders.encoding)
    }

    func readValueXY() throws -> ACad.XY? {
        let length = try mergedReaders.readBitLong()
        return length > 0 ? try mergedReaders.read2RawDouble() : nil
    }

    func readValueXYZ() throws -> ACad.XYZ? {
        let length = try mergedReaders.readBitLong()
        return length > 0 ? try mergedReaders.read3RawDouble() : nil
    }
}
