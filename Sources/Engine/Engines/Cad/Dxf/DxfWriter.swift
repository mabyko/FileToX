// DXF writer (ACadSharp 3.8.0 DxfWriter with DxfAsciiWriter and its section writers), ASCII as Filee writes it:
// the same groups in the same order, numbers formatted like .NET's "R" format, values converted like
// System.Convert, "\n" line ends. Entities and objects are in DxfWriter+Entities.swift and DxfWriter+Objects.swift.

import Foundation

extension ACad {
    /// An exception of the writer, with the message .NET would give.
    struct DxfWriteError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
        static let nullReference = DxfWriteError("Object reference not set to an instance of an object.")
    }

    /// A value given to `Write(code, object)`: what .NET would box.
    enum DxfOut {
        case string(String)
        case double(Double)
        case integer(Int64)
        case unsigned(UInt64)
        case bool(Bool)
        case bytes(Data)

        static func int<T: BinaryInteger>(_ value: T) -> DxfOut { .integer(Int64(value)) }
    }

    final class DxfWriter {
        /// `DxfWriterConfiguration.Variables`: the header variables written by default.
        static let headerVariables: Set<String> = [
            "$ACADVER", "$DWGCODEPAGE", "$LASTSAVEDBY", "$HANDSEED", "$ANGBASE", "$ANGDIR", "$ATTMODE", "$AUNITS", "$AUPREC",
            "$CECOLOR", "$CELTSCALE", "$CELTYPE", "$CELWEIGHT", "$CLAYER", "$CMLJUST", "$CMLSCALE", "$CMLSTYLE", "$DIMSTYLE",
            "$TEXTSIZE", "$TEXTSTYLE", "$LUNITS", "$LUPREC", "$MIRRTEXT", "$EXTNAMES", "$INSBASE", "$INSUNITS", "$MEASUREMENT",
            "$LTSCALE", "$LWDISPLAY", "$PDMODE", "$PDSIZE", "$PLINEGEN", "$PSLTSCALE", "$SPLINESEGS", "$SURFU", "$SURFV",
            "$TDCREATE", "$TDUCREATE", "$TDUPDATE", "$TDUUPDATE", "$TDINDWG",
        ]

        let document: Document
        /// `OnNotification` messages, for the log.
        private(set) var notifications: [String] = []
        /// `WriteXData` / `WriteXRecords` / `WriteDynamicBlockData` / `WriteShapes` of the default configuration.
        let writeXData = true, writeXRecords = true, writeDynamicBlockData = false, writeShapes = false

        private var output = ""
        /// `CadObjectHolder`: entities of model and paper space, and the objects to write, in queue order.
        var heldEntities: [Entity] = []
        var heldObjects: [CadObject] = []
        private var heldObjectsHead = 0

        init(document: Document) {
            self.document = document
        }

        var version: Version { document.header.version }

        func notify(_ message: String) { notifications.append(message) }

        /// `DxfWriter.Write(path, document, binary: false, configuration)`; the text of the file.
        func write() throws -> Data {
            // CadWriterBase.Write
            document.updateImageReactors()
            document.updateDxfClasses(reset: false)
            guard version >= .ac1021 else {
                // Filee writes AC1032 only; the code page encodings of older versions are not ported.
                throw DxfWriteError("DXF versions before AC1021 are not supported by this writer.")
            }
            output.reserveCapacity(1 << 20)
            if let root = document.rootDictionary { heldObjects.append(root) }
            try writeSection(DxfFileToken.headerSection) { try writeHeader() }
            try writeSection(DxfFileToken.classesSection) { try writeClasses() }
            try writeSection(DxfFileToken.tablesSection) { try writeTables() }
            try writeSection(DxfFileToken.blocksSection) { try writeBlocks() }
            try writeSection(DxfFileToken.entitiesSection) {
                var i = 0
                while i < heldEntities.count {
                    try writeEntity(heldEntities[i])
                    i += 1
                }
            }
            try writeSection(DxfFileToken.objectsSection) { try writeObjectsSection() }
            try write(0, .string(DxfFileToken.endOfFile))
            return Data(output.utf8)
        }

        /// Writes a document to a file path (UTF-8, no byte order mark).
        static func write(_ document: Document, to url: URL) throws -> [String] {
            let writer = DxfWriter(document: document)
            let data = try writer.write()
            try data.write(to: url)
            return writer.notifications
        }

        // ───────────────────────── Stream (DxfStreamWriterBase / DxfAsciiWriter) ─────────────────────────

        private func writeCode(_ code: Int) {
            if code < 10 {
                output += "  \(code)\n"
            } else if code < 100 {
                output += " \(code)\n"
            } else {
                output += "\(code)\n"
            }
        }

        /// `Write(code, value, map)`: `angle` stands for a map whose property for the code is `IsAngle`.
        func write(_ code: Int, _ value: DxfOut?, angle: Bool = false) throws {
            guard var value else { return }
            if angle {
                guard case let .double(radians) = value else {
                    throw DxfWriteError("Specified cast is not valid.")
                }
                value = .double(MathHelper.radToDeg(radians))
            }
            writeCode(code)
            if case let .string(s) = value {
                let escaped = s.replacingOccurrences(of: "^", with: "^ ")
                    .replacingOccurrences(of: "\n", with: "^J")
                    .replacingOccurrences(of: "\r", with: "^M")
                    .replacingOccurrences(of: "\t", with: "^I")
                try writeValue(code, .string(escaped))
            } else {
                try writeValue(code, value)
            }
        }

        func write(_ code: Int, _ value: String?) throws { try write(code, value.map { .string($0) }) }
        func write(_ code: Int, _ value: Double, angle: Bool = false) throws { try write(code, .double(value), angle: angle) }
        func write<T: BinaryInteger>(_ code: Int, _ value: T) throws { try write(code, .integer(Int64(value))) }
        func write(_ code: Int, _ value: Bool) throws { try write(code, .bool(value)) }
        func writeHandleValue(_ code: Int, _ value: UInt64) throws { try write(code, .unsigned(value)) }

        /// `Write(code, IVector)`: one group per component, codes 10 apart.
        func write(_ code: Int, _ value: XYZ, angle: Bool = false) throws {
            try write(code, value.x, angle: angle)
            try write(code + 10, value.y, angle: angle)
            try write(code + 20, value.z, angle: angle)
        }

        func write(_ code: Int, _ value: XY, angle: Bool = false) throws {
            try write(code, value.x, angle: angle)
            try write(code + 10, value.y, angle: angle)
        }

        /// `WriteHandle`: nothing for a null reference.
        func writeHandle(_ code: Int, _ object: CadObject?) throws {
            guard let object else { return }
            try write(code, .unsigned(object.handle))
        }

        /// `WriteName`: nothing for a null reference.
        func writeName(_ code: Int, _ name: String?) throws {
            guard let name else { return }
            try write(code, name)
        }

        /// `WriteCmColor`: an index for 16-bit codes, else the flagged 32-bit value.
        func writeCmColor(_ code: Int, _ color: Color) throws {
            if GroupCodeValueType.of(code) == .int16 {
                try write(code, color.approxIndex())
            } else {
                let rgb = color.rgb
                let value: UInt32 = color.isTrueColor
                    ? UInt32(rgb.b) | UInt32(rgb.g) << 8 | UInt32(rgb.r) << 16 | 0xC2 << 24
                    : UInt32(UInt8(truncatingIfNeeded: color.index)) | 0xC1 << 24
                try write(code, .integer(Int64(Int32(bitPattern: value))))
            }
        }

        /// `WriteTrueColor`: 0x00RRGGBB.
        func writeTrueColor(_ code: Int, _ color: Color) throws {
            let rgb = color.rgb
            try write(code, .integer(Int64(Int32(rgb.b) | Int32(rgb.g) << 8 | Int32(rgb.r) << 16)))
        }

        /// `WriteIfNotDefault`.
        func writeIfNotDefault<T: BinaryInteger>(_ code: Int, _ value: T, _ defaultValue: T) throws {
            if value != defaultValue { try write(code, value) }
        }

        func writeIfNotDefault(_ code: Int, _ value: Double, _ defaultValue: Double) throws {
            if !value.isEqual(to: defaultValue) { try write(code, value) }
        }

        /// `DxfAsciiWriter.writeValue`: the text of a value for the code's value type.
        private func writeValue(_ code: Int, _ value: DxfOut) throws {
            switch GroupCodeValueType.of(code) {
            case .string, .comment, .extendedDataString:
                output += DxfWriter.text(value)
            case .point3D, .double, .extendedDataDouble:
                output += DxfNumber.netString(try DxfWriter.double(value))
            case .byte, .int16, .extendedDataInt16, .bool:
                output += String(try DxfWriter.integer(value, Int64(Int16.min)...Int64(Int16.max), "Int16"))
            case .int32, .extendedDataInt32:
                output += String(try DxfWriter.integer(value, Int64(Int32.min)...Int64(Int32.max), "Int32"))
            case .int64:
                output += String(try DxfWriter.integer(value, Int64.min...Int64.max, "Int64"))
            case .handle, .objectId, .extendedDataHandle:
                guard case let .unsigned(handle) = value else {
                    throw DxfWriteError("Unable to cast object of type '\(DxfWriter.typeName(value))' to type 'System.UInt64'.")
                }
                output += String(handle, radix: 16, uppercase: true)
            case .chunk, .extendedDataChunk:
                guard case let .bytes(data) = value else { throw DxfWriteError.nullReference }
                writeChunks(code, data)
                return
            case .none:
                output += DxfWriter.text(value)
            }
            output += "\n"
        }

        /// Binary chunks: 127 bytes per line, the code repeated before each further line.
        private func writeChunks(_ code: Int, _ data: Data) {
            let bytes = [UInt8](data)
            var lines: [String] = []
            var index = 0
            while index < bytes.count {
                let end = min(index + 127, bytes.count)
                lines.append(bytes[index..<end].map { String(format: "%02X", $0) }.joined())
                index = end
            }
            // ACadSharp writes the first line unconditionally (First() of an empty list throws).
            output += (lines.first ?? "") + "\n"
            for line in lines.dropFirst() {
                output += "\(code)\n\(line)\n"
            }
        }

        private static func typeName(_ value: DxfOut) -> String {
            switch value {
            case .string: return "System.String"
            case .double: return "System.Double"
            case .integer: return "System.Int32"
            case .unsigned: return "System.UInt64"
            case .bool: return "System.Boolean"
            case .bytes: return "System.Byte[]"
            }
        }

        /// `object.ToString()`.
        private static func text(_ value: DxfOut) -> String {
            switch value {
            case let .string(s): return s
            case let .double(d): return DxfNumber.netString(d)
            case let .integer(i): return String(i)
            case let .unsigned(u): return String(u)
            case let .bool(b): return b ? "True" : "False"
            case .bytes: return "System.Byte[]"
            }
        }

        /// `Convert.ToDouble`.
        private static func double(_ value: DxfOut) throws -> Double {
            switch value {
            case let .double(d): return d
            case let .integer(i): return Double(i)
            case let .unsigned(u): return Double(u)
            case let .bool(b): return b ? 1 : 0
            case let .string(s):
                guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else {
                    throw DxfWriteError("The input string '\(s)' was not in a correct format.")
                }
                return d
            case .bytes: throw DxfWriteError("Unable to cast object of type 'System.Byte[]' to type 'System.IConvertible'.")
            }
        }

        /// `Convert.ToInt16/32/64`: checked, doubles rounded to even.
        private static func integer(_ value: DxfOut, _ range: ClosedRange<Int64>, _ name: String) throws -> Int64 {
            let overflow = DxfWriteError("Value was either too large or too small for an \(name).")
            switch value {
            case let .integer(i):
                guard range.contains(i) else { throw overflow }
                return i
            case let .unsigned(u):
                guard u <= UInt64(range.upperBound) else { throw overflow }
                return Int64(u)
            case let .bool(b):
                return b ? 1 : 0
            case let .double(d):
                let rounded = d.rounded(.toNearestOrEven)
                guard rounded.isFinite, rounded >= Double(range.lowerBound), rounded <= Double(range.upperBound) else { throw overflow }
                return Int64(rounded)
            case let .string(s):
                guard let i = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                    throw DxfWriteError("The input string '\(s)' was not in a correct format.")
                }
                guard range.contains(i) else { throw overflow }
                return i
            case .bytes:
                throw DxfWriteError("Unable to cast object of type 'System.Byte[]' to type 'System.IConvertible'.")
            }
        }

        // ───────────────────────── Sections ─────────────────────────

        private func writeSection(_ name: String, _ body: () throws -> Void) throws {
            try write(0, DxfFileToken.beginSection)
            try write(2, name)
            try body()
            try write(0, DxfFileToken.endSection)
        }

        /// `DxfHeaderSectionWriter`: the default variables in property order.
        private func writeHeader() throws {
            let header = document.header
            for variable in CadHeader.variables {
                guard DxfWriter.headerVariables.contains(variable.name), !variable.ignored else { continue }
                if case let .optionalString(path) = variable.accessor, header[keyPath: path] == nil { continue }
                try write(9, variable.name)
                if variable.name == "$HANDSEED" {
                    try write(5, .unsigned(header.handleSeed))
                    continue
                }
                if variable.name == "$CECOLOR" {
                    try write(62, header.currentEntityColor.approxIndex())
                    continue
                }
                for code in variable.codes {
                    guard let value = DxfWriter.systemValue(variable, code, header) else { continue }
                    try write(code, value)
                }
            }
        }

        /// `CadSystemVariable.GetSystemValue` for the value kinds of the header.
        private static func systemValue(_ variable: CadHeader.Variable, _ code: Int, _ header: CadHeader) -> DxfOut? {
            let axis = (code / 10) % 10 - 1
            switch variable.accessor {
            case let .double(p): return .double(header[keyPath: p])
            case let .int16(p): return .integer(Int64(header[keyPath: p]))
            case let .uint16(p): return .integer(Int64(header[keyPath: p]))
            case let .int32(p): return .integer(Int64(header[keyPath: p]))
            case let .int64(p): return .integer(header[keyPath: p])
            case let .uint8(p): return .integer(Int64(header[keyPath: p]))
            case let .uint64(p): return .unsigned(header[keyPath: p])
            case let .bool(p): return .bool(header[keyPath: p])
            case let .string(p): return .string(header[keyPath: p])
            case let .optionalString(p): return header[keyPath: p].map { .string($0) }
            case let .xyz(p): return .double(header[keyPath: p][axis])
            case let .xy(p): return .double(axis == 0 ? header[keyPath: p].x : header[keyPath: p].y)
            case let .color(p):
                let color = header[keyPath: p]
                switch code {
                case 62, 70, 176, 177, 178: return .integer(Int64(color.index))
                case 420: return .integer(Int64(color.trueColor))
                default: return nil
                }
            case let .lineWeight(p): return .integer(Int64(header[keyPath: p].rawValue))
            case let .date(p): return .double(header[keyPath: p].julian)
            case let .timeSpan(p): return .double(header[keyPath: p].totalDays)
            }
        }

        /// `DxfClassesSectionWriter`.
        private func writeClasses() throws {
            for item in document.classes {
                try write(0, DxfFileToken.classEntry)
                try write(1, item.dxfName)
                try write(2, item.cppClassName)
                try write(3, item.applicationName)
                try write(90, item.proxyFlags)
                if version > .ac1015 { try write(91, item.instanceCount) }
                try write(280, item.wasZombie)
                try write(281, item.isAnEntity)
            }
        }

        // ───────────────────────── Common data ─────────────────────────

        /// `writeCommonObjectData`.
        func writeCommonObjectData(_ object: CadObject) throws {
            try write(object is DimensionStyle ? 105 : 5, .unsigned(object.handle))
            if let xdict = object.xDictionary {
                try write(102, DxfFileToken.dictionaryToken)
                try write(360, .unsigned(xdict.handle))
                try write(102, "}")
                heldObjects.append(xdict)
            }
            cleanReactors(object)
            if !object.reactors.isEmpty {
                try write(102, DxfFileToken.reactorsToken)
                for reactor in object.reactors { try write(330, .unsigned(reactor)) }
                try write(102, "}")
            }
            try write(330, .unsigned(object.ownerHandle))
        }

        /// `CleanReactors`: reactors outside the document are dropped.
        private func cleanReactors(_ object: CadObject) {
            object.reactors.removeAll { document.object($0) == nil && !document.retiredHandles.contains($0) }
        }

        /// `writeExtendedData`.
        func writeExtendedData(_ object: CadObject) throws {
            guard writeXData, object.hasExtendedData else { return }
            for (app, data) in object.extendedData.entries {
                try write(1001, app.name)
                for record in data.records {
                    switch record {
                    case let .string(s): try write(1000, s)
                    case let .controlString(isClosing): try write(1002, isClosing ? "}" : "{")
                    case let .layer(handle):
                        try write(1005, .unsigned(document.object(handle) is Layer ? handle : 0))
                    case let .binaryChunk(data): try write(1004, .bytes(data))
                    case let .handle(handle):
                        try write(1005, .unsigned(document.object(handle) != nil ? handle : 0))
                    case let .coordinate(v): try write(1010, v)
                    case let .worldCoordinate(v): try write(1011, v)
                    case let .displacement(v): try write(1012, v)
                    case let .direction(v): try write(1013, v)
                    case let .real(d): try write(1040, d)
                    case let .distance(d): try write(1041, d)
                    case let .scale(d): try write(1042, d)
                    case let .integer16(v): try write(1070, v)
                    case let .integer32(v): try write(1071, v)
                    }
                }
            }
        }

        /// `writeCommonEntityData`.
        func writeCommonEntityData(_ entity: Entity) throws {
            try write(100, DxfSubclassMarker.entity)
            try write(8, entity.layer.name)
            try write(6, entity.lineType.name)
            if let book = entity.bookColor {
                try write(62, book.color.approxIndex())
                try writeTrueColor(420, book.color)
                try write(430, book.name)
            } else if entity.color.isTrueColor {
                try writeTrueColor(420, entity.color)
            } else {
                try write(62, entity.color.index)
            }
            if entity.transparency.value >= 0 {
                try write(440, Transparency.toAlphaValue(entity.transparency))
            }
            try write(48, entity.lineTypeScale)
            try write(60, Int16(entity.isInvisible ? 1 : 0))
            if let record = entity.owner as? BlockRecord, let layout = record.layout {
                try write(67, Int16(layout.isPaperSpace ? 1 : 0))
            }
            try write(370, entity.lineWeight.rawValue)
        }

        /// `writeLongTextValue`: 250 UTF-16 units per group, the rest in the last one.
        func writeLongTextValue(_ code: Int, _ subcode: Int, _ text: String?) throws {
            var units = Array((text ?? "").utf16)
            while units.count > 250 {
                try write(subcode, String(decoding: units[0..<250], as: UTF16.self))
                units.removeFirst(250)
            }
            try write(code, String(decoding: units, as: UTF16.self))
        }

        /// `writeCadValue`.
        func writeCadValue(_ value: CadValue) throws {
            try write(93, value.flags)
            try write(90, value.valueType)
            switch value.valueType {
            case CadValueType.unknown, CadValueType.date, CadValueType.buffer, CadValueType.resultBuffer:
                try write(91, 0)
            case CadValueType.double:
                guard case let .double(d)? = value.value else { throw DxfWriteError.nullReference }
                try write(140, d)
            case CadValueType.general, CadValueType.string:
                guard case let .string(s)? = value.value else {
                    if value.value == nil { try writeLongTextValue(1, 2, nil); break }
                    throw DxfWriteError("Unable to cast object to type 'System.String'.")
                }
                try writeLongTextValue(1, 2, s)
            case CadValueType.point2D, CadValueType.point3D:
                switch value.value {
                case let .point3D(v)?: try write(11, v)
                default: throw DxfWriteError("Specified cast is not valid.")
                }
            case CadValueType.long:
                guard case let .int(i)? = value.value else { throw DxfWriteError.nullReference }
                try write(91, i)
            case CadValueType.handle:
                if case let .object(object)? = value.value { try writeHandle(330, object) }
            default:
                break
            }
            try write(304, DxfFileToken.valueEnd)
        }

        // ───────────────────────── Tables ─────────────────────────

        /// `DxfTablesSectionWriter`.
        private func writeTables() throws {
            try writeTable(document.vports)
            try writeTable(document.lineTypes)
            try writeTable(document.layers)
            try writeTable(document.textStyles)
            try writeTable(document.views)
            try writeTable(document.ucss)
            try writeTable(document.appIds)
            try writeTable(document.dimensionStyles, subclass: DxfSubclassMarker.dimensionStyleTable)
            try writeTable(document.blockRecords, writeFlags: false)
        }

        private func writeTable<T: TableEntry>(_ table: Table<T>, subclass: String? = nil, writeFlags: Bool = true) throws {
            try write(0, DxfFileToken.tableEntry)
            try write(2, table.objectName)
            try writeCommonObjectData(table)
            try write(100, DxfSubclassMarker.table)
            try write(70, Int16(table.count > Int(Int16.max) ? 0 : table.count))
            if let subclass, !subclass.isEmpty { try write(100, subclass) }
            for entry in table {
                guard try entry.isValid(format: .dxf, version: version) else {
                    notify("\(type(of: entry)) with name \(entry.name) is not valid for version \(version).")
                    continue
                }
                try writeEntry(entry, writeFlags: writeFlags)
            }
            try write(0, DxfFileToken.endTable)
        }

        private func writeEntry(_ entry: TableEntry, writeFlags: Bool) throws {
            try write(0, entry.objectName)
            try writeCommonObjectData(entry)
            try write(100, DxfSubclassMarker.tableRecord)
            try write(100, entry.subclassMarker)
            if let style = entry as? TextStyle, style.isShapeFile {
                try write(2, "")
            } else {
                try write(2, entry.name)
            }
            if writeFlags { try write(70, entry.flags) }
            switch entry {
            case is AppId: break
            case let block as BlockRecord: try writeBlockRecord(block)
            case let style as DimensionStyle: try writeDimensionStyle(style)
            case let layer as Layer: try writeLayer(layer)
            case let lineType as LineType: try writeLineType(lineType)
            case let style as TextStyle: try writeTextStyle(style)
            case let ucs as UCS: try writeUcs(ucs)
            case let view as View: try writeView(view)
            case let vport as VPort: try writeVPort(vport)
            default: throw DxfWriteError("TableEntry not implemented \(type(of: entry))")
            }
            try writeExtendedData(entry)
        }

        private func writeBlockRecord(_ block: BlockRecord) throws {
            try writeHandle(340, block.layout)
            try write(70, block.units)
            try write(280, UInt8(block.isExplodable ? 1 : 0))
            try write(281, UInt8(block.canScale ? 1 : 0))
        }

        private func writeDimensionStyle(_ style: DimensionStyle) throws {
            try write(3, style.postFix)
            try write(4, style.alternateDimensioningSuffix)
            try write(40, style.scaleFactor)
            try write(41, style.arrowSize)
            try write(42, style.extensionLineOffset)
            try write(43, style.dimensionLineIncrement)
            try write(44, style.extensionLineExtension)
            try write(45, style.rounding)
            try write(46, style.dimensionLineExtension)
            try write(47, style.plusTolerance)
            try write(48, style.minusTolerance)
            try write(49, style.fixedExtensionLineLength)
            try write(50, style.joggedRadiusDimensionTransverseSegmentAngle, angle: true)
            if style.textBackgroundFillMode != 0 {
                try write(69, Int16(truncatingIfNeeded: style.textBackgroundFillMode))
                try write(70, style.textBackgroundColor.approxIndex())
            } else {
                try write(70, 0)
            }
            // ArcLengthSymbolPosition.AboveDimensionText is 1.
            if style.arcLengthSymbolPosition != 1 {
                try write(90, Int32(style.arcLengthSymbolPosition))
            }
            try write(140, style.textHeight)
            try write(141, style.centerMarkSize)
            try write(142, style.tickSize)
            try write(143, style.alternateUnitScaleFactor)
            try write(144, style.linearScaleFactor)
            try write(145, style.textVerticalPosition)
            try write(146, style.toleranceScaleFactor)
            try write(147, style.dimensionLineGap)
            try write(148, style.alternateUnitRounding)
            try write(71, Int16(style.generateTolerances ? 1 : 0))
            try write(72, Int16(style.limitsGeneration ? 1 : 0))
            try write(73, Int16(style.textInsideHorizontal ? 1 : 0))
            try write(74, Int16(style.textOutsideHorizontal ? 1 : 0))
            try write(75, Int16(style.suppressFirstExtensionLine ? 1 : 0))
            try write(76, Int16(style.suppressSecondExtensionLine ? 1 : 0))
            try write(77, Int16(truncatingIfNeeded: style.textVerticalAlignment))
            try write(78, Int16(truncatingIfNeeded: style.zeroHandling))
            try write(79, Int16(truncatingIfNeeded: style.angularZeroHandling))
            try write(170, Int16(style.alternateUnitDimensioning ? 1 : 0))
            try write(171, style.alternateUnitDecimalPlaces)
            try write(172, Int16(style.textOutsideExtensions ? 1 : 0))
            try write(173, Int16(style.separateArrowBlocks ? 1 : 0))
            try write(174, Int16(style.textInsideExtensions ? 1 : 0))
            try write(175, Int16(style.suppressOutsideExtensions ? 1 : 0))
            try write(176, style.dimensionLineColor.approxIndex())
            try write(177, style.extensionLineColor.approxIndex())
            try write(178, style.textColor.approxIndex())
            try write(179, style.angularDecimalPlaces)
            try write(271, style.decimalPlaces)
            try write(272, style.toleranceDecimalPlaces)
            try write(273, Int16(truncatingIfNeeded: style.alternateUnitFormat))
            try write(274, style.alternateUnitToleranceDecimalPlaces)
            try write(275, Int16(truncatingIfNeeded: style.angularUnit))
            try write(276, Int16(truncatingIfNeeded: style.fractionFormat))
            try write(277, Int16(truncatingIfNeeded: style.linearUnitFormat))
            try write(278, Int16(truncatingIfNeeded: style.decimalSeparator))
            try write(279, Int16(truncatingIfNeeded: style.textMovement))
            try write(280, UInt8(truncatingIfNeeded: style.textHorizontalAlignment))
            try write(281, style.suppressFirstDimensionLine)
            try write(282, style.suppressSecondDimensionLine)
            try write(283, UInt8(truncatingIfNeeded: style.toleranceAlignment))
            try write(284, UInt8(truncatingIfNeeded: style.toleranceZeroHandling))
            try write(285, UInt8(truncatingIfNeeded: style.alternateUnitZeroHandling))
            try write(286, UInt8(truncatingIfNeeded: style.alternateUnitToleranceZeroHandling))
            try write(287, UInt8(truncatingIfNeeded: style.dimensionFit))
            try write(288, style.cursorUpdate)
            try write(289, UInt8(truncatingIfNeeded: style.dimensionTextArrowFit))
            try write(290, style.isExtensionLineLengthFixed)
            try writeHandle(340, style.style)
            try writeHandle(341, style.leaderArrow)
            try writeHandle(342, style.arrowBlock)
            try writeHandle(343, style.dimArrow1)
            try writeHandle(344, style.dimArrow2)
            try write(371, style.dimensionLineWeight.rawValue)
            try write(372, style.extensionLineWeight.rawValue)
        }

        private func writeLayer(_ layer: Layer) throws {
            let index = layer.color.isTrueColor ? layer.color.approxIndex() : layer.color.index
            try write(62, Int64(layer.isOn ? Int(index) : -Int(index)))
            if layer.color.isTrueColor { try writeTrueColor(420, layer.color) }
            try write(6, layer.lineType.name)
            try write(290, layer.plotFlag)
            try write(370, layer.lineWeight.rawValue)
            try write(390, .unsigned(0))
        }

        private func writeLineType(_ lineType: LineType) throws {
            try write(3, lineType.description)
            try write(72, Int16(truncatingIfNeeded: lineType.alignment.utf16.first ?? 0))
            try write(73, Int16(truncatingIfNeeded: lineType.segments.count))
            try write(40, lineType.patternLength)
            for segment in lineType.segments {
                try write(49, segment.length)
                try write(74, segment.flags)
                guard segment.flags != 0 else { continue }
                if segment.flags & LineTypeShapeFlags.shape != 0 { try write(75, segment.shapeNumber) }
                if segment.flags & LineTypeShapeFlags.text != 0 { try write(75, Int16(0)) }
                try write(340, .unsigned(segment.style?.handle ?? 0))
                try write(46, segment.scale)
                try write(50, MathHelper.radToDeg(segment.rotation))
                try write(44, segment.offset.x)
                try write(45, segment.offset.y)
                try write(9, segment.text)
            }
        }

        private func writeTextStyle(_ style: TextStyle) throws {
            if !style.filename.isEmpty { try write(3, style.filename) }
            if let bigFont = style.bigFontFilename, !bigFont.isEmpty { try write(4, bigFont) }
            try write(40, style.height)
            try write(41, style.width)
            try write(42, style.lastHeight)
            try write(50, style.obliqueAngle, angle: true)
            try write(71, style.mirrorFlag)
        }

        private func writeUcs(_ ucs: UCS) throws {
            try write(10, ucs.origin.x)
            try write(20, ucs.origin.y)
            try write(30, ucs.origin.z)
            try write(11, ucs.xAxis.x)
            try write(21, ucs.xAxis.y)
            try write(31, ucs.xAxis.z)
            try write(12, ucs.yAxis.x)
            try write(22, ucs.yAxis.y)
            try write(32, ucs.yAxis.z)
            try write(71, ucs.orthographicType)
            try write(79, ucs.orthographicViewType)
            try write(146, ucs.elevation)
        }

        private func writeView(_ view: View) throws {
            try write(40, view.height)
            try write(41, view.width)
            try write(42, view.lensLength)
            try write(43, view.frontClipping)
            try write(44, view.backClipping)
            try write(10, view.center)
            try write(11, view.direction)
            try write(12, view.target)
            try write(50, view.angle, angle: true)
            try write(71, Int16(truncatingIfNeeded: view.viewMode))
            try write(72, view.isUcsAssociated)
            try write(79, Int16(truncatingIfNeeded: view.ucsOrthographicType))
            try write(281, UInt8(truncatingIfNeeded: view.renderMode))
            try write(110, view.ucsOrigin)
            try write(111, view.ucsXAxis)
            try write(112, view.ucsYAxis)
            try write(146, view.ucsElevation)
        }

        private func writeVPort(_ vport: VPort) throws {
            try write(10, vport.bottomLeft)
            try write(11, vport.topRight)
            try write(12, vport.center)
            try write(13, vport.snapBasePoint)
            try write(14, vport.snapSpacing)
            try write(15, vport.gridSpacing)
            try write(16, vport.direction)
            try write(17, vport.target)
            try write(40, vport.viewHeight)
            try write(41, vport.aspectRatio)
            try write(75, Int16(vport.snapOn ? 1 : 0))
            try write(76, Int16(vport.showGrid ? 1 : 0))
        }

        // ───────────────────────── Blocks ─────────────────────────

        /// `DxfBlocksSectionWriter`: model and paper space entities are written in ENTITIES.
        private func writeBlocks() throws {
            for record in document.blockRecords {
                try writeBlock(record.blockEntity)
                let isLayoutSpace = record.name.caseInsensitiveCompare(BlockRecord.modelSpaceName) == .orderedSame
                    || record.name.caseInsensitiveCompare(BlockRecord.paperSpaceName) == .orderedSame
                for entity in record.entities {
                    if isLayoutSpace { heldEntities.append(entity) } else { try writeEntity(entity) }
                }
                try writeBlockEnd(record.blockEnd)
            }
        }

        private func writeBlock(_ block: Block) throws {
            try write(0, block.objectName)
            try writeCommonObjectData(block)
            try writeCommonEntityData(block)
            try write(100, DxfSubclassMarker.blockBegin)
            if let path = block.xRefPath, !path.isEmpty { try write(1, path) }
            try write(2, block.name)
            try write(70, block.blockFlags)
            if version >= .ac1015, block.isUnloaded { try write(71, 1) }
            try write(10, block.basePoint)
            try write(3, block.name)
            try write(4, block.comments)
        }

        private func writeBlockEnd(_ end: BlockEnd) throws {
            try write(0, end.objectName)
            try writeCommonObjectData(end)
            try write(100, DxfSubclassMarker.entity)
            try write(8, end.layer.name)
            try write(100, DxfSubclassMarker.blockEnd)
        }

        // ───────────────────────── Objects ─────────────────────────

        /// `DxfObjectsSectionWriter.writeSection`: the queue, each object once.
        private func writeObjectsSection() throws {
            var written = Set<UInt64>()
            while heldObjectsHead < heldObjects.count {
                let item = heldObjects[heldObjectsHead]
                heldObjectsHead += 1
                guard written.insert(item.handle).inserted else { continue }
                try writeObject(item)
            }
        }
    }

    /// `CadFileFormat` for `IsValid`.
    enum CadFileFormat { case dxf, dwg }
}
