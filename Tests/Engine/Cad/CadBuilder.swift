// Port of tests/Filee.Engines.Tests/CadBuilder.cs: the CAD test drawings. Filee builds them with ACadSharp; here they
// are written as DXF text (AutoCAD 2018, UTF-8, ASCII or binary), so no sample files and no DXF writer are needed.

import Foundation
@testable import FileToXEngineKit

/// A small DXF drawing: layers, line types, dimension styles, blocks and model space entities.
struct CadBuilder {
    /// ACI 5: everything that must be visible is blue.
    static let visible = 5
    /// ACI 1: everything on hidden layers is red, so a red pixel means a hidden layer was drawn.
    static let hidden = 1
    static let koreanText = "도면 제목 Filee"

    typealias Group = (code: Int, value: String)

    struct Layer {
        var name: String
        var color = 7
        var isOn = true
        var isFrozen = false
    }

    var version = "AC1032"
    var codePage: String?
    var headerVariables: [(name: String, groups: [Group])] = []
    var layers: [Layer] = []
    var lineTypes: [(name: String, segments: [Double])] = []
    var dimensionStyles: [(name: String, textHeight: Double, arrowSize: Double)] = []
    var blocks: [(name: String, basePoint: [Double], entities: [[Group]])] = []
    var entities: [[Group]] = []

    // ───────────────────────── Drawings ─────────────────────────

    /// A drawing with lines, a circle, an arc, a polyline with a bulge, TEXT (Korean), MTEXT, a block with an attribute
    /// inserted twice (rotated and scaled), a solid and a pattern hatch, a dashed line, a spline, a partial ellipse, an
    /// aligned dimension, and entities on an OFF and a frozen layer.
    ///
    /// Filee's builder generates the dimension picture with ACadSharp before saving; this file leaves it out, so the
    /// scene builder generates the same picture (ACadSharp's UpdateBlock) when it draws the dimension.
    static func sample() -> CadBuilder {
        var b = CadBuilder()
        b.layers = [Layer(name: "Drawing", color: visible), Layer(name: "Off", color: hidden, isOn: false),
                    Layer(name: "Frozen", color: hidden, isFrozen: true)]

        b.entities.append(line("Drawing", [0, 0], [100, 0]))
        b.entities.append(line("Drawing", [100, 0], [100, 60]))
        b.entities.append(circle("Drawing", [30, 30], 12))
        b.entities.append(arc("Drawing", [70, 30], 10, 0, 180))
        b.entities.append(lwPolyline("Drawing", [(0, 60, 0.5), (40, 60, 0), (40, 80, 0)]))
        b.entities.append(text("Drawing", koreanText, [5, 5], 5))
        b.entities.append(mtext("Drawing", "{\\H1.5x;MTEXT}\\P두 번째 줄 \\S1/2;", [50, 80], 3, width: 60))

        b.blocks.append(("BOLT", [0, 0, 0], [circle("0", [0, 0], 3), line("0", [-5, 0], [5, 0]),
                                            attributeDefinition("ID", "B?", [4, 4], 2)]))
        // A new Insert gets one attribute per definition; the values and positions are set per reference.
        b.entities.append(insert("Drawing", "BOLT", [80, 50], attributes: [("ID", "B1", [84, 54], 2)]))
        b.entities.append(insert("Drawing", "BOLT", [80, 15], scale: 2, rotation: 30, attributes: [("ID", "B2", [84, 19], 2)]))

        b.entities.append(hatch("Drawing", rectangle: [110, 0, 20, 20], pattern: nil))
        // ANSI31-like pattern: 45° lines 2 units apart, stored as AutoCAD stores them (already scaled and rotated).
        b.entities.append(hatch("Drawing", rectangle: [110, 30, 20, 20], pattern: (name: "ANSI31", angle: 45, offset: [-(2.0.squareRoot()), 2.0.squareRoot()])))

        b.lineTypes.append(("DASHED", [5, -2.5]))
        b.entities.append(line("Drawing", [0, -5], [100, -5], lineType: "DASHED"))

        b.entities.append(spline("Drawing", degree: 3, controlPoints: [[0, -20], [20, -10], [40, -30], [60, -20]], knots: [0, 0, 0, 0, 1, 1, 1, 1]))
        b.entities.append(ellipse("Drawing", center: [85, -20], majorAxis: [12, 0], ratio: 0.5, start: 0, end: 1.5 * Double.pi))

        // The default dimension style is sized for inches (0.18 text); this drawing is in millimetres.
        b.dimensionStyles.append(("Filee", 2.5, 2.5))
        b.entities.append(alignedDimension("Drawing", first: [0, 60], second: [100, 60], definition: [100, 68], style: "Filee"))

        b.entities.append(line("Off", [0, 20], [100, 20]))
        b.entities.append(circle("Off", [60, 60], 8))
        b.entities.append(line("Frozen", [0, 40], [100, 40]))
        return b
    }

    /// A few lines around (1 000 000, 500 000) with header extents that point elsewhere.
    static func farFromOrigin() -> CadBuilder {
        var b = CadBuilder()
        b.layers = [Layer(name: "Far", color: 7)]
        let x = 1_000_000.0, y = 500_000.0
        b.entities.append(line("Far", [x, y], [x + 400, y]))
        b.entities.append(line("Far", [x + 400, y], [x + 400, y + 200]))
        b.entities.append(line("Far", [x + 400, y + 200], [x, y + 200]))
        b.entities.append(line("Far", [x, y + 200], [x, y]))
        b.headerVariables.append(("$EXTMIN", [(10, "0"), (20, "0"), (30, "0")]))
        b.headerVariables.append(("$EXTMAX", [(10, "10"), (20, "10"), (30, "0")]))
        return b
    }

    // ───────────────────────── Entities ─────────────────────────

    private static func number(_ value: Double) -> String { ACad.DxfNumber.netString(value) }

    private static func point(_ code: Int, _ p: [Double]) -> [Group] {
        [(code, number(p[0])), (code + 10, number(p[1])), (code + 20, number(p.count > 2 ? p[2] : 0))]
    }

    private static func entity(_ type: String, _ layer: String, _ subclass: String, lineType: String? = nil) -> [Group] {
        var groups: [Group] = [(0, type), (100, "AcDbEntity"), (8, layer)]
        if let lineType { groups.append((6, lineType)) }
        groups.append((100, subclass))
        return groups
    }

    static func line(_ layer: String, _ start: [Double], _ end: [Double], lineType: String? = nil) -> [Group] {
        entity("LINE", layer, "AcDbLine", lineType: lineType) + point(10, start) + point(11, end)
    }

    static func circle(_ layer: String, _ center: [Double], _ radius: Double) -> [Group] {
        entity("CIRCLE", layer, "AcDbCircle") + point(10, center) + [(40, number(radius))]
    }

    static func arc(_ layer: String, _ center: [Double], _ radius: Double, _ startDegrees: Double, _ endDegrees: Double) -> [Group] {
        circle(layer, center, radius).map { $0.code == 0 ? (0, "ARC") : $0 }
            + [(100, "AcDbArc"), (50, number(startDegrees)), (51, number(endDegrees))]
    }

    static func lwPolyline(_ layer: String, _ vertices: [(Double, Double, Double)], closed: Bool = false) -> [Group] {
        var groups = entity("LWPOLYLINE", layer, "AcDbPolyline") + [(90, String(vertices.count)), (70, closed ? "1" : "0")]
        for v in vertices {
            groups += [(10, number(v.0)), (20, number(v.1))]
            if v.2 != 0 { groups.append((42, number(v.2))) }
        }
        return groups
    }

    static func text(_ layer: String, _ value: String, _ insert: [Double], _ height: Double) -> [Group] {
        entity("TEXT", layer, "AcDbText") + point(10, insert) + [(40, number(height)), (1, value), (100, "AcDbText")]
    }

    static func mtext(_ layer: String, _ value: String, _ insert: [Double], _ height: Double, width: Double) -> [Group] {
        entity("MTEXT", layer, "AcDbMText") + point(10, insert) + [(40, number(height)), (41, number(width)), (71, "1"), (1, value)]
    }

    static func attributeDefinition(_ tag: String, _ value: String, _ insert: [Double], _ height: Double) -> [Group] {
        entity("ATTDEF", "0", "AcDbText") + point(10, insert) + [(40, number(height)), (1, value), (100, "AcDbAttributeDefinition"),
                                                                    (3, ""), (2, tag), (70, "0")]
    }

    static func insert(_ layer: String, _ block: String, _ point: [Double], scale: Double = 1, rotation: Double = 0, columns: Int = 1, rows: Int = 1,
                       columnSpacing: Double = 0, rowSpacing: Double = 0, attributes: [(String, String, [Double], Double)] = []) -> [Group] {
        var groups = entity("INSERT", layer, "AcDbBlockReference")
        if !attributes.isEmpty { groups.append((66, "1")) }
        groups += [(2, block)] + CadBuilder.point(10, point)
        groups += [(41, number(scale)), (42, number(scale)), (43, number(scale)), (50, number(rotation)),
                   (70, String(columns)), (71, String(rows)), (44, number(columnSpacing)), (45, number(rowSpacing))]
        for (tag, value, at, height) in attributes {
            groups += entity("ATTRIB", "0", "AcDbText") + CadBuilder.point(10, at) + [(40, number(height)), (1, value), (100, "AcDbAttribute"),
                                                                                       (2, tag), (70, "0")]
        }
        if !attributes.isEmpty { groups += [(0, "SEQEND"), (100, "AcDbEntity"), (8, layer)] }
        return groups
    }

    static func hatch(_ layer: String, rectangle r: [Double], pattern: (name: String, angle: Double, offset: [Double])?) -> [Group] {
        var groups = entity("HATCH", layer, "AcDbHatch") + point(10, [0, 0]) + [(210, "0"), (220, "0"), (230, "1"),
                                                                                (2, pattern?.name ?? "SOLID"), (70, pattern == nil ? "1" : "0"),
                                                                                (71, "0"), (91, "1"), (92, "2"), (72, "0"), (73, "1"), (93, "4")]
        for (x, y) in [(r[0], r[1]), (r[0] + r[2], r[1]), (r[0] + r[2], r[1] + r[3]), (r[0], r[1] + r[3])] {
            groups += [(10, number(x)), (20, number(y))]
        }
        groups += [(97, "0"), (75, "0"), (76, "1")]
        if let pattern {
            groups += [(52, "0"), (41, "1"), (77, "0"), (78, "1"), (53, number(pattern.angle)), (43, "0"), (44, "0"),
                       (45, number(pattern.offset[0])), (46, number(pattern.offset[1])), (79, "0")]
        }
        groups.append((98, "0"))
        return groups
    }

    static func spline(_ layer: String, degree: Int, controlPoints: [[Double]], knots: [Double]) -> [Group] {
        var groups = entity("SPLINE", layer, "AcDbSpline") + [(70, "8"), (71, String(degree)), (72, String(knots.count)),
                                                              (73, String(controlPoints.count)), (74, "0")]
        for k in knots { groups.append((40, number(k))) }
        for p in controlPoints { groups += point(10, p) }
        return groups
    }

    static func ellipse(_ layer: String, center: [Double], majorAxis: [Double], ratio: Double, start: Double, end: Double) -> [Group] {
        entity("ELLIPSE", layer, "AcDbEllipse") + point(10, center) + point(11, majorAxis)
            + [(210, "0"), (220, "0"), (230, "1"), (40, number(ratio)), (41, number(start)), (42, number(end))]
    }

    static func alignedDimension(_ layer: String, first: [Double], second: [Double], definition: [Double], style: String) -> [Group] {
        entity("DIMENSION", layer, "AcDbDimension") + point(10, definition) + point(11, [0, 0]) + [(70, "33"), (3, style), (100, "AcDbAlignedDimension")]
            + point(13, first) + point(14, second)
    }

    // ───────────────────────── Output ─────────────────────────

    /// The drawing's group codes, section by section, with a handle for every object and the owner of each record and
    /// entity (block entities belong to their block record through it).
    func groups() -> [Group] {
        var next = 0x10
        func handle() -> String {
            defer { next += 1 }
            return String(next, radix: 16, uppercase: true)
        }
        /// An object: its type, handle and owner, then the rest of its groups.
        func object(_ groups: [Group], owner: String) -> [Group] {
            [groups[0], (5, handle()), (330, owner)] + groups.dropFirst()
        }
        /// Entities in the order given; an entity's ATTRIB and SEQEND records belong to it.
        func entities(_ list: [[Group]], owner: String) -> [Group] {
            var out: [Group] = []
            for groups in list {
                var start = 0
                var parent = owner
                for i in 1...groups.count where i == groups.count || groups[i].code == 0 {
                    let piece = Array(groups[start..<i])
                    let id = String(next, radix: 16, uppercase: true)
                    out += object(piece, owner: start == 0 ? owner : parent)
                    if start == 0 { parent = id }
                    start = i
                }
            }
            return out
        }
        func table(_ name: String, _ records: [[Group]]) -> [Group] {
            let id = handle()
            var out: [Group] = [(0, "TABLE"), (2, name), (5, id), (330, "0"), (100, "AcDbSymbolTable"), (70, String(records.count))]
            for record in records { out += object(record, owner: id) }
            return out + [(0, "ENDTAB")]
        }

        var tables: [Group] = []
        tables += table("LTYPE", lineTypes.map { lineType in
            var g: [Group] = [(0, "LTYPE"), (100, "AcDbSymbolTableRecord"), (100, "AcDbLinetypeTableRecord"), (2, lineType.name), (70, "0"), (3, ""),
                              (72, "65"), (73, String(lineType.segments.count)), (40, CadBuilder.number(lineType.segments.reduce(0) { $0 + abs($1) }))]
            for segment in lineType.segments { g += [(49, CadBuilder.number(segment)), (74, "0")] }
            return g
        })
        tables += table("LAYER", layers.map { layer in
            [(0, "LAYER"), (100, "AcDbSymbolTableRecord"), (100, "AcDbLayerTableRecord"), (2, layer.name), (70, layer.isFrozen ? "1" : "0"),
             (62, String(layer.isOn ? layer.color : -layer.color)), (6, "Continuous")]
        })
        tables += table("DIMSTYLE", dimensionStyles.map { style in
            [(0, "DIMSTYLE"), (100, "AcDbSymbolTableRecord"), (100, "AcDbDimStyleTableRecord"), (2, style.name), (70, "0"),
             (41, CadBuilder.number(style.arrowSize)), (140, CadBuilder.number(style.textHeight))]
        })
        let allBlocks: [(name: String, basePoint: [Double], entities: [[Group]])] =
            [("*Model_Space", [0, 0, 0], []), ("*Paper_Space", [0, 0, 0], [])] + blocks
        let recordTable = handle()
        var recordHandles: [String] = []
        tables += [(0, "TABLE"), (2, "BLOCK_RECORD"), (5, recordTable), (330, "0"), (100, "AcDbSymbolTable"), (70, String(allBlocks.count))]
        for block in allBlocks {
            recordHandles.append(String(next, radix: 16, uppercase: true))
            tables += object([(0, "BLOCK_RECORD"), (100, "AcDbSymbolTableRecord"), (100, "AcDbBlockTableRecord"), (2, block.name)], owner: recordTable)
        }
        tables.append((0, "ENDTAB"))

        var blockSection: [Group] = []
        for (block, owner) in zip(allBlocks, recordHandles) {
            blockSection += object([(0, "BLOCK"), (100, "AcDbEntity"), (8, "0"), (100, "AcDbBlockBegin"), (2, block.name), (70, "0")]
                + CadBuilder.point(10, block.basePoint) + [(3, block.name), (1, "")], owner: owner)
            blockSection += entities(block.entities, owner: owner)
            blockSection += object([(0, "ENDBLK"), (100, "AcDbEntity"), (8, "0"), (100, "AcDbBlockEnd")], owner: owner)
        }
        let entitySection = entities(self.entities, owner: recordHandles[0])

        var g: [Group] = [(0, "SECTION"), (2, "HEADER"), (9, "$ACADVER"), (1, version)]
        if let codePage { g += [(9, "$DWGCODEPAGE"), (3, codePage)] }
        g += [(9, "$HANDSEED"), (5, String(next, radix: 16, uppercase: true))]
        for variable in headerVariables { g += [(9, variable.name)] + variable.groups }
        g += [(0, "ENDSEC"), (0, "SECTION"), (2, "TABLES")] + tables + [(0, "ENDSEC")]
        g += [(0, "SECTION"), (2, "BLOCKS")] + blockSection + [(0, "ENDSEC")]
        g += [(0, "SECTION"), (2, "ENTITIES")] + entitySection + [(0, "ENDSEC"), (0, "EOF")]
        return g
    }

    /// ASCII DXF text in UTF-8, or in the given encoding for pre-2007 versions.
    func dxf(encoding: String.Encoding = .utf8) -> Data {
        var text = ""
        for (code, value) in groups() { text += "\(code)\n\(value)\n" }
        return text.data(using: encoding, allowLossyConversion: false)!
    }

    /// Binary DXF: the sentinel, then each group as a 2-byte code and a value typed by the code.
    func binaryDxf() -> Data {
        var data = Data("AutoCAD Binary DXF\r\n\u{1a}\0".utf8)
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for (code, value) in groups() {
            le(Int16(code))
            switch ACad.GroupCodeValueType.of(code) {
            case .point3D, .double, .extendedDataDouble: le(Double(value)!.bitPattern)
            case .byte, .int16, .extendedDataInt16: le(Int16(value)!)
            case .int32, .extendedDataInt32: le(Int32(value)!)
            case .int64: le(Int64(value)!)
            case .bool: data.append(value == "0" ? 0 : 1)
            default:
                data.append(contentsOf: Array(value.utf8))
                data.append(0)
            }
        }
        return data
    }

    @discardableResult
    func save(_ folder: String, _ name: String, binary: Bool = false) throws -> String {
        let path = FilePath.combine(folder, name)
        try (binary ? binaryDxf() : dxf()).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Model space entity counts by DXF type name.
    static func census(_ document: ACad.Document) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entity in document.entities { counts[entity.objectName, default: 0] += 1 }
        return counts
    }
}
