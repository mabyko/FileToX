// ACadSharp 3.8.0 `DwgObjectReader`: the readers of the graphical entities (lines, curves, text, inserts, polylines,
// dimensions, hatches, leaders, images, modeler geometry, viewports and proxies).

import Foundation

extension ACad.DwgObjectReader {
    typealias XYZ = ACad.XYZ
    typealias XY = ACad.XY
    private typealias DwgError = ACad.DwgError

    // ───────────────────────── Simple entities ─────────────────────────

    func read3dFace() throws -> ACad.CadTemplate? {
        let face = ACad.Face3D()
        let template = ACad.CadEntityTemplate(face)
        try readCommonEntityData(template)

        // R13 - R14 Only:
        if r13_14Only {
            face.firstCorner = try objectReader.read3BitDouble()
            face.secondCorner = try objectReader.read3BitDouble()
            face.thirdCorner = try objectReader.read3BitDouble()
            face.fourthCorner = try objectReader.read3BitDouble()
            // Invis flags BS 70 Invisible edge flags
            face.flags = try objectReader.readBitShort()
        }

        // R2000 +:
        if r2000Plus {
            // Has no flag ind. B
            let noFlags = try objectReader.readBit()
            // Z is zero bit B
            let zIsZero = try objectReader.readBit()
            let x = try objectReader.readDouble()
            let y = try objectReader.readDouble()
            var z = 0.0
            if !zIsZero { z = try objectReader.readDouble() }
            face.firstCorner = XYZ(x, y, z)
            // 2nd / 3rd / 4th corner 3DD, each defaulting to the previous one
            face.secondCorner = try objectReader.read3BitDoubleWithDefault(face.firstCorner)
            face.thirdCorner = try objectReader.read3BitDoubleWithDefault(face.secondCorner)
            face.fourthCorner = try objectReader.read3BitDoubleWithDefault(face.thirdCorner)
            // Invis flags BS 70 Present it “Has no flag ind.” is 0.
            if !noFlags { face.flags = try objectReader.readBitShort() }
        }
        return template
    }

    func readArc() throws -> ACad.CadTemplate? {
        let arc = ACad.Arc()
        let template = ACad.CadEntityTemplate(arc)
        try readCommonEntityData(template)
        arc.center = try objectReader.read3BitDouble()
        let radius = try objectReader.readBitDouble()
        arc.radius = radius <= 0 ? ACad.MathHelper.epsilon : radius
        arc.thickness = try objectReader.readBitThickness()
        arc.normal = try objectReader.readBitExtrusion()
        arc.startAngle = try objectReader.readBitDouble()
        arc.endAngle = try objectReader.readBitDouble()
        return template
    }

    func readBlock() throws -> ACad.CadTemplate? {
        // `new Block(new BlockRecord())`: the name lives on the temporary record until SetBlockToRecord.
        let block = ACad.BlockRecord(name: "").blockEntity
        let template = ACad.CadEntityTemplate(block)
        try readCommonEntityData(template)
        // Block name TV 2
        let name = try textReader.readVariableText()
        if !name.allSatisfy(\.isWhitespace) {
            block.name = name
        }
        return template
    }

    func readEndBlock() throws -> ACad.CadTemplate? {
        let template = ACad.CadEntityTemplate(ACad.BlockRecord(name: "").blockEnd)
        try readCommonEntityData(template)
        return template
    }

    func readCircle() throws -> ACad.CadTemplate? {
        let circle = ACad.Circle()
        let template = ACad.CadEntityTemplate(circle)
        try readCommonEntityData(template)
        circle.center = try objectReader.read3BitDouble()
        let radius = try objectReader.readBitDouble()
        circle.radius = radius <= 0 ? ACad.MathHelper.epsilon : radius
        circle.thickness = try objectReader.readBitThickness()
        circle.normal = try objectReader.readBitExtrusion()
        return template
    }

    func readEllipse() throws -> ACad.CadTemplate? {
        let ellipse = ACad.Ellipse()
        let template = ACad.CadEntityTemplate(ellipse)
        try readCommonEntityData(template)
        ellipse.center = try objectReader.read3BitDouble()
        ellipse.majorAxisEndPoint = try objectReader.read3BitDouble()
        ellipse.normal = try objectReader.read3BitDouble()
        let ratio = try objectReader.readBitDouble()
        // The RadiusRatio setter.
        if ratio <= 0 || ratio > 1 { throw DwgError("Radius ratio must be a value between 0 (not included) and 1. (Parameter 'value')") }
        ellipse.radiusRatio = ratio
        ellipse.startParameter = try objectReader.readBitDouble()
        ellipse.endParameter = try objectReader.readBitDouble()
        return template
    }

    func readLine() throws -> ACad.CadTemplate? {
        let line = ACad.Line()
        let template = ACad.CadEntityTemplate(line)
        try readCommonEntityData(template)

        if r13_14Only {
            line.startPoint = try objectReader.read3BitDouble()
            line.endPoint = try objectReader.read3BitDouble()
        }

        if r2000Plus {
            // Z’s are zero bit B
            let flag = try objectReader.readBit()
            let startX = try objectReader.readDouble()
            let endX = try objectReader.readBitDoubleWithDefault(startX)
            let startY = try objectReader.readDouble()
            let endY = try objectReader.readBitDoubleWithDefault(startY)
            var startZ = 0.0
            var endZ = 0.0
            if !flag {
                startZ = try objectReader.readDouble()
                endZ = try objectReader.readBitDoubleWithDefault(startZ)
            }
            line.startPoint = XYZ(startX, startY, startZ)
            line.endPoint = XYZ(endX, endY, endZ)
        }

        line.thickness = try objectReader.readBitThickness()
        line.normal = try objectReader.readBitExtrusion()
        return template
    }

    func readPoint() throws -> ACad.CadTemplate? {
        let point = ACad.Point()
        let template = ACad.CadEntityTemplate(point)
        try readCommonEntityData(template)
        point.location = try objectReader.read3BitDouble()
        point.thickness = try objectReader.readBitThickness()
        point.normal = try objectReader.readBitExtrusion()
        // X - axis ang BD 50
        point.rotation = try objectReader.readBitDouble()
        return template
    }

    func readRay() throws -> ACad.CadTemplate? {
        let ray = ACad.Ray()
        let template = ACad.CadEntityTemplate(ray)
        try readCommonEntityData(template)
        ray.startPoint = try objectReader.read3BitDouble()
        ray.direction = try objectReader.read3BitDouble()
        return template
    }

    func readXLine() throws -> ACad.CadTemplate? {
        let xline = ACad.XLine()
        let template = ACad.CadEntityTemplate(xline)
        try readCommonEntityData(template)
        xline.firstPoint = try objectReader.read3BitDouble()
        xline.direction = try objectReader.read3BitDouble()
        return template
    }

    func readSeqend() throws -> ACad.CadTemplate? {
        let template = ACad.CadEntityTemplate(ACad.Seqend())
        try readCommonEntityData(template)
        return template
    }

    func readShape() throws -> ACad.CadTemplate? {
        let shape = ACad.Shape()
        let template = ACad.CadShapeTemplate(shape)
        try readCommonEntityData(template)
        shape.insertionPoint = try objectReader.read3BitDouble()
        shape.size = try objectReader.readBitDouble()
        shape.rotation = try objectReader.readBitDouble()
        shape.relativeXScale = try objectReader.readBitDouble()
        shape.obliqueAngle = try objectReader.readBitDouble()
        shape.thickness = try objectReader.readBitDouble()
        // Shapeno BS 2: the shape index (DXF stores the name).
        shape.shapeIndex = UInt16(bitPattern: try objectReader.readBitShort())
        shape.normal = try objectReader.read3BitDouble()
        // H SHAPEFILE (hard pointer)
        template.shapeFileHandle = try handleReference()
        return template
    }

    func readSolid() throws -> ACad.CadTemplate? {
        let solid = ACad.Solid()
        let template = ACad.CadEntityTemplate(solid)
        try readCommonEntityData(template)
        solid.thickness = try objectReader.readBitThickness()
        // Elevation BD ---Z for 10 - 13.
        let elevation = try objectReader.readBitDouble()
        let first = try objectReader.read2RawDouble()
        solid.firstCorner = XYZ(first.x, first.y, elevation)
        let second = try objectReader.read2RawDouble()
        solid.secondCorner = XYZ(second.x, second.y, elevation)
        let third = try objectReader.read2RawDouble()
        solid.thirdCorner = XYZ(third.x, third.y, elevation)
        let fourth = try objectReader.read2RawDouble()
        solid.fourthCorner = XYZ(fourth.x, fourth.y, elevation)
        solid.normal = try objectReader.readBitExtrusion()
        return template
    }

    func readSpline() throws -> ACad.CadTemplate? {
        let spline = ACad.Spline()
        let template = ACad.CadEntityTemplate(spline)
        try readCommonEntityData(template)

        // Scenario BL a flag which is 2 for fitpts only, 1 for ctrlpts/knots.
        var scenario = try objectReader.readBitLong()

        if r2013Plus {
            // Spline flags 1 BL: method fit points = 1, CV frame show = 2, Is closed = 4, Use knot parameter = 8
            spline.flags1 = try mergedReaders.readBitLong()
            // The IsClosed setter keeps both flag sets in step.
            if spline.flags1 & 4 != 0 {
                spline.flags |= ACad.SplineFlags.closed
                spline.flags1 |= 4
            } else {
                spline.flags &= ~ACad.SplineFlags.closed
                spline.flags1 &= ~4
            }
            // Knot parameter BL: Chord = 0, Square root = 1, Uniform = 2, Custom = 15
            spline.knotParametrization = try mergedReaders.readBitLong()
            scenario = (spline.knotParametrization == 15 || spline.flags1 & 8 == 0) ? 1 : 2
        } else if scenario == 2 {
            spline.flags1 |= 1
        } else {
            // If the spline does not have fit data, then the knot parameter should become Custom.
            spline.knotParametrization = 15
        }

        // Degree BL degree of this spline
        spline.degree = try objectReader.readBitLong()

        var numfitpts: Int32 = 0
        var numknots: Int32 = 0
        var numctrlpts: Int32 = 0
        var flag = false
        switch scenario {
        case 1:
            if try objectReader.readBit() { spline.flags |= ACad.SplineFlags.rational }
            if try objectReader.readBit() { spline.flags |= ACad.SplineFlags.closed }
            if try objectReader.readBit() { spline.flags |= ACad.SplineFlags.periodic }
            spline.knotTolerance = try objectReader.readBitDouble()
            spline.controlPointTolerance = try objectReader.readBitDouble()
            numknots = try objectReader.readBitLong()
            numctrlpts = try objectReader.readBitLong()
            // Weight B Seems to be an echo of the 4 bit on the flag for "weights present".
            flag = try objectReader.readBit()
        case 2:
            spline.fitTolerance = try objectReader.readBitDouble()
            spline.startTangent = try objectReader.read3BitDouble()
            spline.endTangent = try objectReader.read3BitDouble()
            numfitpts = try objectReader.readBitLong()
        default: break
        }

        for _ in 0..<max(0, numknots) {
            spline.knots.append(try objectReader.readBitDouble())
        }
        for _ in 0..<max(0, numctrlpts) {
            spline.controlPoints.append(try objectReader.read3BitDouble())
            if flag { spline.weights.append(try objectReader.readBitDouble()) }
        }
        for _ in 0..<max(0, numfitpts) {
            spline.fitPoints.append(try objectReader.read3BitDouble())
        }
        return template
    }

    // ───────────────────────── Polylines ─────────────────────────

    func readLWPolyline() throws -> ACad.CadTemplate? {
        let lwPolyline = ACad.LwPolyline()
        let template = ACad.CadEntityTemplate(lwPolyline)
        do {
            try readCommonEntityData(template)

            let flags = try objectReader.readBitShort()
            if flags & 0x100 != 0 { lwPolyline.flags |= 128 } // Plinegen
            if flags & 0x200 != 0 { lwPolyline.flags |= 1 } // Closed
            if flags & 0x4 != 0 { lwPolyline.constantWidth = try objectReader.readBitDouble() }
            if flags & 0x8 != 0 { lwPolyline.elevation = try objectReader.readBitDouble() }
            if flags & 0x2 != 0 { lwPolyline.thickness = try objectReader.readBitDouble() }
            if flags & 0x1 != 0 { lwPolyline.normal = try objectReader.read3BitDouble() }

            let nvertices = try objectReader.readBitLong()
            var nbulges: Int32 = 0
            if flags & 0x10 != 0 { nbulges = try objectReader.readBitLong() }
            var nids: Int32 = 0
            if flags & 0x400 != 0 { nids = try objectReader.readBitLong() }
            var ndiffwidth: Int32 = 0
            if flags & 0x20 != 0 { ndiffwidth = try objectReader.readBitLong() }

            if r13_14Only {
                for _ in 0..<max(0, nvertices) {
                    lwPolyline.vertices.append(Self.lwVertex(try objectReader.read2RawDouble()))
                }
            }

            if r2000Plus && nvertices > 0 {
                var loc = try objectReader.read2RawDouble()
                lwPolyline.vertices.append(Self.lwVertex(loc))
                for _ in 1..<nvertices {
                    loc = try objectReader.read2BitDoubleWithDefault(loc)
                    lwPolyline.vertices.append(Self.lwVertex(loc))
                }
            }

            for k in 0..<Int(max(0, nbulges)) {
                let bulge = try objectReader.readBitDouble()
                try Self.checkIndex(k, lwPolyline.vertices.count)
                lwPolyline.vertices[k].bulge = bulge
            }
            for l in 0..<Int(max(0, nids)) {
                let id = try objectReader.readBitLong()
                try Self.checkIndex(l, lwPolyline.vertices.count)
                lwPolyline.vertices[l].id = id
            }
            for m in 0..<Int(max(0, ndiffwidth)) {
                try Self.checkIndex(m, lwPolyline.vertices.count)
                lwPolyline.vertices[m].startWidth = try objectReader.readBitDouble()
                lwPolyline.vertices[m].endWidth = try objectReader.readBitDouble()
            }
        } catch {
            builder.notify("Exception while reading LwPolyline: \(Self.dotNetExceptionName(error))")
            return template
        }
        return template
    }

    private static func lwVertex(_ location: XY) -> ACad.LwPolyline.Vertex { ACad.LwPolyline.Vertex(location.x, location.y) }

    /// `List<T>[index]` throws `ArgumentOutOfRangeException` where a Swift array would trap.
    static func checkIndex(_ index: Int, _ count: Int) throws {
        if index < 0 || index >= count {
            throw DwgError("Index was out of range. Must be non-negative and less than the size of the collection. (Parameter 'index')")
        }
    }

    /// `ex.GetType().FullName` for the exceptions a reader can raise.
    static func dotNetExceptionName(_ error: Error) -> String {
        let message = (error as? ACad.DwgError)?.message ?? ""
        if message == ACad.DwgError.endOfStream.message { return "System.IO.EndOfStreamException" }
        if message.hasPrefix("Index was out of range") { return "System.ArgumentOutOfRangeException" }
        if message == ACad.DwgError.notImplemented.message { return "System.NotImplementedException" }
        return "System.Exception"
    }

    func readPolyfaceMesh() throws -> ACad.CadTemplate? {
        let template = ACad.CadPolyLineTemplate(ACad.PolyfaceMesh())
        try readCommonEntityData(template)
        // Numverts BS 71, Numfaces BS 72
        _ = try objectReader.readBitShort()
        _ = try objectReader.readBitShort()
        if r2004Plus {
            let ownedVertices = try objectReader.readBitLong()
            for _ in 0..<max(0, ownedVertices) {
                template.ownedObjectsHandlers.insert(try handleReference())
            }
        }
        if r13_15Only {
            template.firstVertexHandle = try handleReference()
            template.lastVertexHandle = try handleReference()
        }
        // H SEQEND(hard owner)
        template.seqendHandle = try handleReference()
        return template
    }

    func readPolyline2D() throws -> ACad.CadTemplate? {
        let pline = ACad.Polyline2D()
        let template = ACad.CadPolyLineTemplate(pline)
        try readCommonEntityData(template)
        pline.flags = try objectReader.readBitShort()
        pline.smoothSurface = try objectReader.readBitShort()
        pline.startWidth = try objectReader.readBitDouble()
        pline.endWidth = try objectReader.readBitDouble()
        pline.thickness = try objectReader.readBitThickness()
        pline.elevation = try objectReader.readBitDouble()
        pline.normal = try objectReader.readBitExtrusion()
        if r2004Plus {
            let nownedObjects = try objectReader.readBitLong()
            for _ in 0..<max(0, nownedObjects) {
                template.ownedObjectsHandlers.insert(try handleReference())
            }
        }
        if version >= .ac1012 && version <= .ac1015 {
            template.firstVertexHandle = try handleReference()
            template.lastVertexHandle = try handleReference()
        }
        template.seqendHandle = try handleReference()
        return template
    }

    func readPolyline3D() throws -> ACad.CadTemplate? {
        let pline = ACad.Polyline3D()
        let template = ACad.CadPolyLineTemplate(pline)
        try readCommonEntityData(template)

        // Flags RC 70 NOT DIRECTLY THE 75: bit 0 / 1 splined.
        let flags = try objectReader.readByte()
        if flags & 0b1 != 0 || flags & 0b10 != 0 {
            pline.flags |= ACad.PolylineFlags.splineFit
        }
        // Flags RC 70: bit 0 closed (and 8 because this is a 3D POLYLINE).
        pline.flags |= ACad.PolylineFlags.polyline3D
        if try objectReader.readByte() & 1 != 0 {
            pline.flags |= ACad.PolylineFlags.closed
        }
        if r2004Plus {
            let nownedObjects = try objectReader.readBitLong()
            for _ in 0..<max(0, nownedObjects) {
                template.ownedObjectsHandlers.insert(try handleReference())
            }
        }
        if version >= .ac1012 && version <= .ac1015 {
            template.firstVertexHandle = try handleReference()
            template.lastVertexHandle = try handleReference()
        }
        template.seqendHandle = try handleReference()
        return template
    }

    func readPolylineMesh() throws -> ACad.CadTemplate? {
        let pline = ACad.PolygonMesh()
        let template = ACad.CadPolyLineTemplate(pline)
        try readCommonEntityData(template)
        pline.flags = try objectReader.readBitShort()
        pline.smoothSurface = try objectReader.readBitShort()
        pline.mVertexCount = try objectReader.readBitShort()
        pline.nVertexCount = try objectReader.readBitShort()
        pline.mSmoothSurfaceDensity = try objectReader.readBitShort()
        pline.nSmoothSurfaceDensity = try objectReader.readBitShort()
        if r13_15Only {
            template.firstVertexHandle = try handleReference()
            template.lastVertexHandle = try handleReference()
        }
        if r2004Plus {
            let n = try objectReader.readBitLong()
            for _ in 0..<max(0, n) {
                template.ownedObjectsHandlers.insert(try handleReference())
            }
        }
        template.seqendHandle = try handleReference()
        return template
    }

    func readVertex2D() throws -> ACad.CadTemplate? {
        let vertex = ACad.Vertex2D()
        let template = ACad.CadEntityTemplate(vertex)
        try readCommonEntityData(template)
        // Flags EC 70 NOT bit-pair-coded.
        vertex.flags = Int16(try objectReader.readByte())
        vertex.location = try objectReader.read3BitDouble()
        // Start width BD 40: negative means start and end width are both its absolute value.
        let width = try objectReader.readBitDouble()
        if width < 0 {
            vertex.startWidth = -width
            vertex.endWidth = -width
        } else {
            vertex.startWidth = width
            vertex.endWidth = try objectReader.readBitDouble()
        }
        vertex.bulge = try objectReader.readBitDouble()
        if r2010Plus { vertex.id = try objectReader.readBitLong() }
        vertex.curveTangent = try objectReader.readBitDouble()
        return template
    }

    func readVertex3D(_ vertex: ACad.Vertex) throws -> ACad.CadTemplate? {
        let template = ACad.CadEntityTemplate(vertex)
        try readCommonEntityData(template)
        vertex.flags = Int16(try objectReader.readByte())
        vertex.location = try objectReader.read3BitDouble()
        return template
    }

    func readPfaceVertex() throws -> ACad.CadTemplate? {
        let face = ACad.VertexFaceRecord()
        let template = ACad.CadEntityTemplate(face)
        try readCommonEntityData(template)
        face.index1 = try objectReader.readBitShort()
        face.index2 = try objectReader.readBitShort()
        face.index3 = try objectReader.readBitShort()
        face.index4 = try objectReader.readBitShort()
        return template
    }

    // ───────────────────────── Text ─────────────────────────

    func readText() throws -> ACad.CadTemplate? {
        let template = ACad.CadTextEntityTemplate(ACad.TextEntity())
        try readCommonTextData(template)
        return template
    }

    func readAttribute() throws -> ACad.CadTemplate? {
        let template = ACad.CadTextEntityTemplate(ACad.AttributeEntity())
        try readCommonTextData(template)
        try readCommonAttData(template)
        return template
    }

    func readAttributeDefinition() throws -> ACad.CadTemplate? {
        let attdef = ACad.AttributeDefinition()
        let template = ACad.CadTextEntityTemplate(attdef)
        try readCommonTextData(template)
        try readCommonAttData(template)
        // R2010+: Version RC ? Repeated??
        if r2010Plus { attdef.version = try objectReader.readByte() }
        // Prompt TV 3
        attdef.prompt = try textReader.readVariableText()
        return template
    }

    func readCommonAttData(_ template: ACad.CadTextEntityTemplate) throws {
        let att = template.cadObject as! ACad.AttributeBase
        if r2010Plus { att.version = try objectReader.readByte() }
        if r2018Plus { att.attributeType = try objectReader.readByte() }

        switch att.attributeType {
        case ACad.AttributeType.multiLine, ACad.AttributeType.constantMultiLine:
            // The fields of an embedded MTEXT, starting from the entity mode; the owner handle can be 0.
            let mtext = ACad.MText()
            att.mtext = mtext
            let mtextTemplate = ACad.CadTextEntityTemplate(mtext)
            template.mtextTemplate = mtextTemplate
            try readEntityMode(mtextTemplate)
            _ = try readMText(mtextTemplate, false)
            let dataSize = try objectReader.readBitShort()
            if dataSize > 0 {
                // Annotative data bytes RC, Registered application H, Unknown BS 72
                _ = try objectReader.readBytes(Int(dataSize))
                _ = try handleReference()
                _ = try objectReader.readBitShort()
            }
        default: break
        }

        // Tag TV 2
        att.tag = try textReader.readVariableText()
        // Field length BS 73 unused
        _ = try objectReader.readBitShort()
        // Flags RC 70 NOT bit-pair - coded.
        att.flags = Int16(try objectReader.readByte())
        if r2007Plus { att.isLocked = try objectReader.readBit() }
    }

    func readCommonTextData(_ template: ACad.CadTextEntityTemplate) throws {
        try readCommonEntityData(template)
        let text = template.cadObject as! ACad.TextEntity
        var elevation = 0.0

        if r13_14Only {
            elevation = try objectReader.readBitDouble()
            var pt = try objectReader.read2RawDouble()
            text.insertPoint = XYZ(pt.x, pt.y, elevation)
            pt = try objectReader.read2RawDouble()
            text.alignmentPoint = XYZ(pt.x, pt.y, elevation)
            text.normal = try objectReader.read3BitDouble()
            text.thickness = try objectReader.readBitDouble()
            text.obliqueAngle = try objectReader.readBitDouble()
            text.rotation = try objectReader.readBitDouble()
            text.height = try objectReader.readBitDouble()
            text.widthFactor = try objectReader.readBitDouble()
            text.value = try textReader.readVariableText()
            text.mirror = try objectReader.readBitShort()
            text.horizontalAlignment = try objectReader.readBitShort()
            text.verticalAlignment = try objectReader.readBitShort()
            // H 7 STYLE(hard pointer)
            template.styleHandle = try handleReference()
            return
        }

        // DataFlags RC Used to determine presence of subsquent data
        let dataFlags = try objectReader.readByte()
        if dataFlags & 0x1 == 0 { elevation = try objectReader.readDouble() }
        let pt = try objectReader.read2RawDouble()
        text.insertPoint = XYZ(pt.x, pt.y, elevation)
        if dataFlags & 0x2 == 0 {
            let x = try objectReader.readBitDoubleWithDefault(text.insertPoint.x)
            let y = try objectReader.readBitDoubleWithDefault(text.insertPoint.y)
            text.alignmentPoint = XYZ(x, y, elevation)
        }
        text.normal = try objectReader.readBitExtrusion()
        text.thickness = try objectReader.readBitThickness()
        if dataFlags & 0x4 == 0 { text.obliqueAngle = try objectReader.readDouble() }
        if dataFlags & 0x8 == 0 { text.rotation = try objectReader.readDouble() }
        text.height = try objectReader.readDouble()
        if dataFlags & 0x10 == 0 { text.widthFactor = try objectReader.readDouble() }
        text.value = try textReader.readVariableText()
        if dataFlags & 0x20 == 0 { text.mirror = try objectReader.readBitShort() }
        if dataFlags & 0x40 == 0 { text.horizontalAlignment = try objectReader.readBitShort() }
        if dataFlags & 0x80 == 0 { text.verticalAlignment = try objectReader.readBitShort() }
        // H 7 STYLE(hard pointer)
        template.styleHandle = try handleReference()
    }

    func readMText() throws -> ACad.CadTemplate? {
        try readMText(ACad.CadTextEntityTemplate(ACad.MText()), true)
    }

    func readMText(_ template: ACad.CadTextEntityTemplate, _ readCommonData: Bool) throws -> ACad.CadTemplate? {
        let mtext = template.cadObject as! ACad.MText
        if readCommonData { try readCommonEntityData(template) }

        mtext.insertPoint = try objectReader.read3BitDouble()
        mtext.normal = try objectReader.read3BitDouble()
        // X-axis dir 3BD 11
        mtext.alignmentPoint = try objectReader.read3BitDouble()
        mtext.rectangleWidth = try objectReader.readBitDouble()
        if r2007Plus { mtext.rectangleHeight = try objectReader.readBitDouble() }
        mtext.height = try objectReader.readBitDouble()
        mtext.attachmentPoint = try objectReader.readBitShort()
        mtext.drawingDirection = try objectReader.readBitShort()
        // Extents ht / wid BD (undocumented)
        _ = try objectReader.readBitDouble()
        _ = try objectReader.readBitDouble()
        mtext.value = try textReader.readVariableText()
        // H 7 STYLE (hard pointer)
        template.styleHandle = try handleReference()

        if r2000Plus {
            mtext.lineSpacingStyle = try objectReader.readBitShort()
            mtext.lineSpacing = try objectReader.readBitDouble()
            // Unknown bit B
            _ = try objectReader.readBit()
        }

        if r2004Plus {
            // Background flags BL 90: 1 = background fill, 2 = drawing fill color, 0x10 = text frame (R2018+)
            mtext.backgroundFillFlags = try objectReader.readBitLong()
            if mtext.backgroundFillFlags & 1 != 0 || version > .ac1027 && mtext.backgroundFillFlags & 0x10 > 0 {
                mtext.backgroundScale = try objectReader.readBitDouble()
                mtext.backgroundColor = try mergedReaders.readCmColor(useTextStream: false)
                mtext.backgroundTransparency = try Self.transparency(try objectReader.readBitLong())
            }
        }

        guard r2018Plus else { return template }

        // Is NOT annotative B
        mtext.isAnnotative = !(try objectReader.readBit())
        if !mtext.isAnnotative {
            // Version BS, Default flag B
            _ = try objectReader.readBitShort()
            _ = try objectReader.readBit()
            // Redundant fields: registered application H, attachment BL, x-axis dir, insertion point,
            // rect width / height, extents width / height.
            _ = try handleReference()
            _ = try objectReader.readBitLong()
            _ = try objectReader.read3BitDouble()
            _ = try objectReader.read3BitDouble()
            _ = try objectReader.readBitDouble()
            _ = try objectReader.readBitDouble()
            _ = try objectReader.readBitDouble()
            _ = try objectReader.readBitDouble()

            // Column type BS 71 0 = No columns, 1 = static columns, 2 = dynamic columns
            mtext.columnData.columnType = try objectReader.readBitShort()
            if mtext.columnData.columnType != 0 {
                let count = try objectReader.readBitLong()
                mtext.columnData.width = try objectReader.readBitDouble()
                mtext.columnData.gutter = try objectReader.readBitDouble()
                mtext.columnData.autoHeight = try objectReader.readBit()
                mtext.columnData.flowReversed = try objectReader.readBit()
                if !mtext.columnData.autoHeight && mtext.columnData.columnType == 2 && count > 0 {
                    for _ in 0..<count {
                        mtext.columnData.heights.append(try objectReader.readBitDouble())
                    }
                }
            }
        }
        return template
    }

    /// `new Transparency((short)value)`: the setter rejects values outside 0 … 90 besides -1 and 100.
    static func transparency(_ raw: Int32) throws -> ACad.Transparency {
        let value = Int16(truncatingIfNeeded: raw)
        if value != -1 && value != 100 && (value < 0 || value > 90) {
            throw DwgError("Transparency must be in range from 0 to 90. (Parameter 'value')\nActual value was \(value).")
        }
        return ACad.Transparency(value)
    }

    // ───────────────────────── Inserts ─────────────────────────

    func readInsert() throws -> ACad.CadTemplate? {
        let template = ACad.CadInsertTemplate(ACad.Insert())
        try readInsertCommonData(template)
        try readInsertCommonHandles(template)
        return template
    }

    func readMInsert() throws -> ACad.CadTemplate? {
        let insert = ACad.Insert()
        let template = ACad.CadInsertTemplate(insert)
        try readInsertCommonData(template)
        insert.columnCount = UInt16(bitPattern: try objectReader.readBitShort())
        insert.rowCount = UInt16(bitPattern: try objectReader.readBitShort())
        insert.columnSpacing = try objectReader.readBitDouble()
        insert.rowSpacing = try objectReader.readBitDouble()
        try readInsertCommonHandles(template)
        return template
    }

    func readInsertCommonData(_ template: ACad.CadInsertTemplate) throws {
        let insert = template.cadObject as! ACad.Insert
        try readCommonEntityData(template)
        insert.insertPoint = try objectReader.read3BitDouble()

        if r13_14Only {
            let scale = try objectReader.read3BitDouble()
            try Self.setScale(insert, x: scale.x)
            try Self.setScale(insert, y: scale.y)
            try Self.setScale(insert, z: scale.z)
        }

        if r2000Plus {
            // Data flags BB
            switch try objectReader.read2Bits() {
            case 0:
                try Self.setScale(insert, x: try objectReader.readDouble())
                try Self.setScale(insert, y: try objectReader.readBitDoubleWithDefault(insert.xScale))
                try Self.setScale(insert, z: try objectReader.readBitDoubleWithDefault(insert.xScale))
            case 1:
                try Self.setScale(insert, y: try objectReader.readBitDoubleWithDefault(insert.xScale))
                try Self.setScale(insert, z: try objectReader.readBitDoubleWithDefault(insert.xScale))
            case 2:
                let xyz = try objectReader.readDouble()
                try Self.setScale(insert, x: xyz)
                try Self.setScale(insert, y: xyz)
                try Self.setScale(insert, z: xyz)
            case 3:
                insert.xScale = 1
                insert.yScale = 1
                insert.zScale = 1
            default: break
            }
        }

        insert.rotation = try objectReader.readBitDouble()
        insert.normal = try objectReader.read3BitDouble()
        // Has ATTRIBs B 66
        template.hasAtts = try objectReader.readBit()
        template.ownedObjectsCount = 0
        if r2004Plus && template.hasAtts {
            template.ownedObjectsCount = Int(try objectReader.readBitLong())
        }
    }

    /// The Insert scale setters, which reject 0.
    private static func setScale(_ insert: ACad.Insert, x: Double? = nil, y: Double? = nil, z: Double? = nil) throws {
        let (name, value) = x.map { ("XScale", $0) } ?? y.map { ("YScale", $0) } ?? ("ZScale", z!)
        if value == 0 { throw DwgError("\(name) value must be none zero. (Parameter '\(name)')\nActual value was 0.") }
        if x != nil { insert.xScale = value } else if y != nil { insert.yScale = value } else { insert.zScale = value }
    }

    func readInsertCommonHandles(_ template: ACad.CadInsertTemplate) throws {
        // H 2 BLOCK HEADER(hard pointer)
        template.blockHeaderHandle = try handleReference()
        guard template.hasAtts else { return }

        if version >= .ac1012 && version <= .ac1015 {
            template.firstAttributeHandle = try handleReference()
            template.endAttributeHandle = try handleReference()
        } else if r2004Plus {
            for _ in 0..<max(0, template.ownedObjectsCount) {
                template.ownedObjectsHandlers.insert(try handleReference())
            }
        }
        // H[SEQEND(hard owner)] if 66 bit set
        template.seqendHandle = try handleReference()
    }

    // ───────────────────────── Dimensions ─────────────────────────

    func readCommonDimensionAlignedData(_ template: ACad.CadDimensionTemplate) throws {
        let dimension = template.cadObject as! ACad.DimensionAligned
        dimension.firstPoint = try objectReader.read3BitDouble()
        dimension.secondPoint = try objectReader.read3BitDouble()
        dimension.definitionPoint = try objectReader.read3BitDouble()
        dimension.extLineRotation = try objectReader.readBitDouble()
    }

    func readCommonDimensionData(_ template: ACad.CadDimensionTemplate) throws {
        try readCommonEntityData(template)
        let dimension = template.dimension

        if r2010Plus { dimension.version = try objectReader.readByte() }
        dimension.normal = try objectReader.read3BitDouble()
        // Text midpt 2RD 11, Elevation BD for the ECS points
        let midpt = try objectReader.read2RawDouble()
        let elevation = try objectReader.readBitDouble()
        dimension.textMiddlePoint = XYZ(midpt.x, midpt.y, elevation)

        // Flags 1 RC: bit 0 is the opposite of bit 7 (128) of 70.
        let flags = try objectReader.readByte()
        dimension.isTextUserDefinedLocation = flags & 0b01 == 0

        dimension.text = try textReader.readVariableText()
        dimension.textRotation = try objectReader.readBitDouble()
        dimension.horizontalDirection = try objectReader.readBitDouble()

        // Ins X / Y / Z - scale BD 41-43 and Ins rotation BD 54 of the anonymous block (not kept).
        _ = try objectReader.readBitDouble()
        _ = try objectReader.readBitDouble()
        _ = try objectReader.readBitDouble()
        _ = try objectReader.readBitDouble()

        if r2000Plus {
            dimension.attachmentPoint = try objectReader.readBitShort()
            dimension.lineSpacingStyle = try objectReader.readBitShort()
            dimension.lineSpacingFactor = try objectReader.readBitDouble()
            // Actual Measurement BD 42
            _ = try objectReader.readBitDouble()
        }

        if r2007Plus {
            // Unknown B 73
            _ = try objectReader.readBit()
            dimension.flipArrow1 = try objectReader.readBit()
            dimension.flipArrow2 = try objectReader.readBit()
        }

        // 12 - pt 2RD 12
        let pt = try objectReader.read2RawDouble()
        dimension.insertionPoint = XYZ(pt.x, pt.y, elevation)
    }

    func readCommonDimensionHandles(_ template: ACad.CadDimensionTemplate) throws {
        // H 3 DIMSTYLE(hard pointer), H 2 anonymous BLOCK(hard pointer)
        template.styleHandle = try handleReference()
        template.blockHandle = try handleReference()
    }

    func readDimArc() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionArc()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        dimension.definitionPoint = try objectReader.read3BitDouble()
        dimension.firstPoint = try objectReader.read3BitDouble()
        dimension.secondPoint = try objectReader.read3BitDouble()
        dimension.center = try objectReader.read3BitDouble()
        dimension.isPartial = try objectReader.readBit()
        dimension.startAngle = try objectReader.readBitDouble()
        dimension.endAngle = try objectReader.readBitDouble()
        dimension.hasLeader = try objectReader.readBit()
        dimension.leaderPoint1 = try objectReader.read3BitDouble()
        dimension.leaderPoint2 = try objectReader.read3BitDouble()
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimAligned() throws -> ACad.CadTemplate? {
        let template = ACad.CadDimensionTemplate(ACad.DimensionAligned())
        try readCommonDimensionData(template)
        try readCommonDimensionAlignedData(template)
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimAngular3pt() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionAngular3Pt()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        dimension.definitionPoint = try objectReader.read3BitDouble()
        dimension.firstPoint = try objectReader.read3BitDouble()
        dimension.secondPoint = try objectReader.read3BitDouble()
        dimension.angleVertex = try objectReader.read3BitDouble()
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimDiameter() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionDiameter()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        dimension.angleVertex = try objectReader.read3BitDouble()
        dimension.definitionPoint = try objectReader.read3BitDouble()
        dimension.leaderLength = try objectReader.readBitDouble()
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimLine2pt() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionAngular2Line()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        // 16-pt 2RD 16
        let xy = try objectReader.read2RawDouble()
        dimension.dimensionArc = XYZ(xy.x, xy.y, dimension.textMiddlePoint.z)
        dimension.firstPoint = try objectReader.read3BitDouble()
        dimension.secondPoint = try objectReader.read3BitDouble()
        dimension.angleVertex = try objectReader.read3BitDouble()
        dimension.definitionPoint = try objectReader.read3BitDouble()
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimLinear() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionLinear()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        try readCommonDimensionAlignedData(template)
        // Dim rot BD 50
        dimension.rotation = try objectReader.readBitDouble()
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimOrdinate() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionOrdinate()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        dimension.definitionPoint = try objectReader.read3BitDouble()
        dimension.featureLocation = try objectReader.read3BitDouble()
        dimension.leaderEndpoint = try objectReader.read3BitDouble()
        let flags = try objectReader.readByte()
        dimension.isOrdinateTypeX = flags & 0b01 != 0
        try readCommonDimensionHandles(template)
        return template
    }

    func readDimRadius() throws -> ACad.CadTemplate? {
        let dimension = ACad.DimensionRadius()
        let template = ACad.CadDimensionTemplate(dimension)
        try readCommonDimensionData(template)
        dimension.definitionPoint = try objectReader.read3BitDouble()
        dimension.angleVertex = try objectReader.read3BitDouble()
        dimension.leaderLength = try objectReader.readBitDouble()
        try readCommonDimensionHandles(template)
        return template
    }

    // ───────────────────────── Hatch, leader, mline, tolerance ─────────────────────────

    func readHatch() throws -> ACad.CadTemplate? {
        let hatch = ACad.Hatch()
        let template = ACad.CadHatchTemplate(hatch)
        try readCommonEntityData(template)

        if r2004Plus {
            // Is Gradient Fill BL 450
            hatch.gradientColor.enabled = try objectReader.readBitLong() != 0
            hatch.gradientColor.reserved = try objectReader.readBitLong()
            hatch.gradientColor.angle = try objectReader.readBitDouble()
            hatch.gradientColor.shift = try objectReader.readBitDouble()
            hatch.gradientColor.isSingleColorGradient = UInt32(bitPattern: try objectReader.readBitLong()) > 0
            hatch.gradientColor.colorTint = try objectReader.readBitDouble()
            let ncolors = try objectReader.readBitLong()
            for _ in 0..<max(0, ncolors) {
                var color = ACad.HatchGradientPattern.GradientColor()
                color.value = try objectReader.readBitDouble()
                color.color = try mergedReaders.readCmColor(useTextStream: false)
                hatch.gradientColor.colors.append(color)
            }
            hatch.gradientColor.name = try textReader.readVariableText()
        }

        // Z coord BD 30 X, Y always 0.0
        hatch.elevation = try objectReader.readBitDouble()
        hatch.normal = try objectReader.read3BitDouble()
        hatch.pattern = ACad.HatchPattern(try textReader.readVariableText())
        hatch.isSolid = try objectReader.readBit()
        hatch.isAssociative = try objectReader.readBit()

        let npaths = try objectReader.readBitLong()
        var hasDerivedBoundary = false
        for _ in 0..<max(0, npaths) {
            let pathTemplate = ACad.CadHatchTemplate.BoundaryPathTemplate()
            let flags = try objectReader.readBitLong()
            pathTemplate.path.flags = flags
            if flags & ACad.BoundaryPathFlags.derived != 0 { hasDerivedBoundary = true }

            if flags & ACad.BoundaryPathFlags.polyline == 0 {
                let nsegments = try objectReader.readBitLong()
                for _ in 0..<max(0, nsegments) {
                    // pathtypestatus RC 72 type of path
                    switch try objectReader.readByte() {
                    case 1:
                        let start = try objectReader.read2RawDouble()
                        let end = try objectReader.read2RawDouble()
                        pathTemplate.path.edges.append(.line(start: start, end: end))
                    case 2:
                        let center = try objectReader.read2RawDouble()
                        let radius = try objectReader.readBitDouble()
                        let startAngle = try objectReader.readBitDouble()
                        let endAngle = try objectReader.readBitDouble()
                        let ccw = try objectReader.readBit()
                        pathTemplate.path.edges.append(.arc(center: center, radius: radius, startAngle: startAngle,
                                                            endAngle: endAngle, counterClockWise: ccw))
                    case 3:
                        let center = try objectReader.read2RawDouble()
                        let major = try objectReader.read2RawDouble()
                        let ratio = try objectReader.readBitDouble()
                        let startAngle = try objectReader.readBitDouble()
                        let endAngle = try objectReader.readBitDouble()
                        let ccw = try objectReader.readBit()
                        pathTemplate.path.edges.append(.ellipse(center: center, majorAxisEndPoint: major, radiusRatio: ratio,
                                                                startAngle: startAngle, endAngle: endAngle, counterClockWise: ccw))
                    case 4:
                        var spline = ACad.Hatch.BoundaryPath.Spline()
                        spline.degree = try objectReader.readBitLong()
                        spline.isRational = try objectReader.readBit()
                        spline.isPeriodic = try objectReader.readBit()
                        let numknots = try objectReader.readBitLong()
                        let numctlpts = try objectReader.readBitLong()
                        for _ in 0..<max(0, numknots) {
                            spline.knots.append(try objectReader.readBitDouble())
                        }
                        for _ in 0..<max(0, numctlpts) {
                            let cp = try objectReader.read2RawDouble()
                            var weight = 0.0
                            if spline.isRational { weight = try objectReader.readBitDouble() }
                            spline.controlPoints.append(XYZ(cp.x, cp.y, weight))
                        }
                        if r2010Plus {
                            let nfitPoints = try objectReader.readBitLong()
                            if nfitPoints > 0 {
                                for _ in 0..<nfitPoints {
                                    spline.fitPoints.append(try objectReader.read2RawDouble())
                                }
                                spline.startTangent = try objectReader.read2RawDouble()
                                spline.endTangent = try objectReader.read2RawDouble()
                            }
                        }
                        pathTemplate.path.edges.append(.spline(spline))
                    default:
                        break
                    }
                }
            } else {
                // POLYLINE PATH
                let bulgesPresent = try objectReader.readBit()
                let isClosed = try objectReader.readBit()
                let numpathsegs = try objectReader.readBitLong()
                var vertices: [XYZ] = []
                for _ in 0..<max(0, numpathsegs) {
                    let vertex = try objectReader.read2RawDouble()
                    var bulge = 0.0
                    if bulgesPresent { bulge = try objectReader.readBitDouble() }
                    vertices.append(XYZ(vertex.x, vertex.y, bulge))
                }
                // `HasBulge` is computed from the bulges.
                pathTemplate.path.edges.append(.polyline(vertices: vertices, isClosed: isClosed,
                                                         hasBulge: vertices.contains { $0.z != 0 }))
            }

            // numboundaryobjhandles BL 97
            let numboundaryobjhandles = try objectReader.readBitLong()
            for _ in 0..<max(0, numboundaryobjhandles) {
                pathTemplate.handles.insert(try handleReference())
            }
            template.pathTemplates.append(pathTemplate)
        }

        hatch.style = try objectReader.readBitShort()
        hatch.patternType = try objectReader.readBitShort()

        if !hatch.isSolid {
            hatch.patternAngle = try objectReader.readBitDouble()
            hatch.patternScale = try objectReader.readBitDouble()
            hatch.isDouble = try objectReader.readBit()
            let numdeflines = try objectReader.readBitShort()
            for _ in 0..<max(0, Int(numdeflines)) {
                let line = ACad.HatchPattern.Line()
                line.angle = try objectReader.readBitDouble()
                line.basePoint = try objectReader.read2BitDouble()
                line.offset = try objectReader.read2BitDouble()
                let ndashes = try objectReader.readBitShort()
                for _ in 0..<max(0, Int(ndashes)) {
                    line.dashLengths.append(try objectReader.readBitDouble())
                }
                hatch.pattern.lines.append(line)
            }
        }

        if hasDerivedBoundary { hatch.pixelSize = try objectReader.readBitDouble() }

        let numseedpoints = try objectReader.readBitLong()
        for _ in 0..<max(0, numseedpoints) {
            hatch.seedPoints.append(try objectReader.read2RawDouble())
        }
        return template
    }

    func readLeader() throws -> ACad.CadTemplate? {
        let leader = ACad.Leader()
        let template = ACad.CadLeaderTemplate(leader)
        try readCommonEntityData(template)

        // Unknown bit B --- Always seems to be 0.
        _ = try objectReader.readBit()
        // Annot type BS: 0 MTEXT, 1 TOLERANCE, 2 INSERT, 3 None
        leader.creationType = try objectReader.readBitShort()
        leader.pathType = try objectReader.readBitShort()
        let npts = try objectReader.readBitLong()
        for _ in 0..<max(0, npts) {
            leader.vertices.append(try objectReader.read3BitDouble())
        }
        // Origin 3BD --- The leader plane origin
        _ = try objectReader.read3BitDouble()
        leader.normal = try objectReader.read3BitDouble()
        leader.horizontalDirection = try objectReader.read3BitDouble()
        leader.blockOffset = try objectReader.read3BitDouble()
        if version >= .ac1014 {
            leader.annotationOffset = try objectReader.read3BitDouble()
        }
        if r13_14Only {
            // DIMGAP BD at the time of creation, times the dimscale
            leader.style.dimensionLineGap = try objectReader.readBitDouble()
        }
        if version <= .ac1021 {
            // For higher versions these values are wrong and it works best if they are not read.
            leader.textHeight = try objectReader.readBitDouble()
            leader.textWidth = try objectReader.readBitDouble()
        }
        // Hooklineonxdir B: 1 Same, 0 Opposite
        leader.hookLineDirection = try objectReader.readBit() ? 1 : 0
        leader.arrowHeadEnabled = try objectReader.readBit()

        if r13_14Only {
            // Arrowheadtype BS
            _ = try objectReader.readBitShort()
            template.dimasz = try objectReader.readBitDouble()
            _ = try objectReader.readBit()
            _ = try objectReader.readBit()
            _ = try objectReader.readBitShort()
            // Byblockcolor BS
            _ = try objectReader.readBitShort()
            _ = try objectReader.readBit()
            _ = try objectReader.readBit()
        }

        if r2000Plus {
            _ = try objectReader.readBitShort()
            _ = try objectReader.readBit()
            _ = try objectReader.readBit()
        }

        // H 340 Associated annotation, H 2 DIMSTYLE (hard pointer)
        template.annotationHandle = try handleReference()
        template.dimStyleHandle = try handleReference()
        return template
    }

    func readMLine() throws -> ACad.CadTemplate? {
        let mline = ACad.MLine()
        let template = ACad.CadMLineTemplate(mline)
        try readCommonEntityData(template)

        mline.scaleFactor = try objectReader.readBitDouble()
        // Just EC top (0), bottom(2), or center(1)
        mline.justification = Int16(try objectReader.readByte())
        mline.startPoint = try objectReader.read3BitDouble()
        mline.normal = try objectReader.read3BitDouble()
        // Openclosed BS open (1), closed(3)
        mline.flags |= try objectReader.readBitShort() == 3 ? ACad.MLineFlags.closed : ACad.MLineFlags.hasVertices
        // Linesinstyle RC 73
        let nlines = Int(try objectReader.readByte())
        // Numverts BS 72
        let nverts = Int(try objectReader.readBitShort())
        for _ in 0..<max(0, nverts) {
            let vertex = ACad.MLine.Vertex()
            vertex.position = try objectReader.read3BitDouble()
            vertex.direction = try objectReader.read3BitDouble()
            vertex.miter = try objectReader.read3BitDouble()
            for _ in 0..<nlines {
                let element = ACad.MLine.Vertex.Segment()
                let nsegparms = Int(try objectReader.readBitShort())
                for _ in 0..<max(0, nsegparms) {
                    element.parameters.append(try objectReader.readBitDouble())
                }
                let nfillparms = Int(try objectReader.readBitShort())
                for _ in 0..<max(0, nfillparms) {
                    element.areaFillParameters.append(try objectReader.readBitDouble())
                }
                vertex.segments.append(element)
            }
            mline.vertices.append(vertex)
        }
        // H mline style oject handle (hard pointer)
        template.mlineStyleHandle = try handleReference()
        return template
    }

    func readTolerance() throws -> ACad.CadTemplate? {
        let tolerance = ACad.Tolerance()
        let template = ACad.CadToleranceTemplate(tolerance)
        try readCommonEntityData(template)
        if r13_14Only {
            // Unknown short S, Height BD, Dimgap(?) BD
            _ = try objectReader.readBitShort()
            _ = try objectReader.readBitDouble()
            _ = try objectReader.readBitDouble()
        }
        tolerance.insertionPoint = try objectReader.read3BitDouble()
        tolerance.direction = try objectReader.read3BitDouble()
        tolerance.normal = try objectReader.read3BitDouble()
        tolerance.text = try textReader.readVariableText()
        // H DIMSTYLE(hard pointer)
        template.dimensionStyleHandle = try handleReference()
        return template
    }

    // ───────────────────────── Viewport ─────────────────────────

    func readViewport() throws -> ACad.CadTemplate? {
        let viewport = ACad.Viewport()
        let template = ACad.CadViewportTemplate(viewport)
        try readCommonEntityData(template)

        viewport.center = try objectReader.read3BitDouble()
        viewport.width = try objectReader.readBitDouble()
        viewport.height = try objectReader.readBitDouble()

        if r2000Plus {
            viewport.viewTarget = try objectReader.read3BitDouble()
            viewport.viewDirection = try objectReader.read3BitDouble()
            viewport.twistAngle = try objectReader.readBitDouble()
            viewport.viewHeight = try objectReader.readBitDouble()
            viewport.lensLength = try objectReader.readBitDouble()
            viewport.frontClipPlane = try objectReader.readBitDouble()
            viewport.backClipPlane = try objectReader.readBitDouble()
            viewport.snapAngle = try objectReader.readBitDouble()
            viewport.viewCenter = try objectReader.read2RawDouble()
            viewport.snapBase = try objectReader.read2RawDouble()
            viewport.snapSpacing = try objectReader.read2RawDouble()
            viewport.gridSpacing = try objectReader.read2RawDouble()
            viewport.circleZoomPercent = try objectReader.readBitShort()
        }

        if r2007Plus { viewport.majorGridLineFrequency = try objectReader.readBitShort() }

        var frozenLayerCount: Int32 = 0
        if r2000Plus {
            frozenLayerCount = try objectReader.readBitLong()
            viewport.status = try objectReader.readBitLong()
            viewport.styleSheetName = try textReader.readVariableText()
            viewport.renderMode = try objectReader.readByte()
            viewport.displayUcsIcon = try objectReader.readBit()
            viewport.ucsPerViewport = try objectReader.readBit()
            viewport.ucsOrigin = try objectReader.read3BitDouble()
            viewport.ucsXAxis = try objectReader.read3BitDouble()
            viewport.ucsYAxis = try objectReader.read3BitDouble()
            viewport.elevation = try objectReader.readBitDouble()
            viewport.ucsOrthographicType = try objectReader.readBitShort()
        }

        if r2004Plus { viewport.shadePlotMode = try objectReader.readBitShort() }

        if r2007Plus {
            viewport.useDefaultLighting = try objectReader.readBit()
            viewport.defaultLightingType = try objectReader.readByte()
            viewport.brightness = try objectReader.readBitDouble()
            viewport.contrast = try objectReader.readBitDouble()
            viewport.ambientLightColor = try objectReader.readCmColor()
        }

        // R13 - R14 Only: H VIEWPORT ENT HEADER(hard pointer)
        if r13_14Only { template.viewportHeaderHandle = try handleReference() }

        if r2000Plus {
            for _ in 0..<max(0, frozenLayerCount) {
                template.frozenLayerHandles.insert(try handleReference())
            }
            // H 340 Clip boundary handle(soft pointer)
            template.boundaryHandle = try handleReference()
        }

        // R2000: H VIEWPORT ENT HEADER((hard pointer))
        if version == .ac1015 { template.viewportHeaderHandle = try handleReference() }

        if r2000Plus {
            template.namedUcsHandle = try handleReference()
            template.baseUcsHandle = try handleReference()
        }

        if r2007Plus {
            // H 332 Background, H 348 Visual Style, H 333 Shadeplot ID, H 361 Sun (not kept)
            _ = try handleReference()
            _ = try handleReference()
            _ = try handleReference()
            _ = try handleReference()
        }
        return template
    }

    // ───────────────────────── Images, underlays, OLE ─────────────────────────

    func readCadImage(_ image: ACad.CadWipeoutBase) throws -> ACad.CadTemplate? {
        let template = ACad.CadWipeoutBaseTemplate(image)
        try readCommonEntityData(template)

        image.classVersion = try objectReader.readBitLong()
        image.insertPoint = try objectReader.read3BitDouble()
        image.uVector = try objectReader.read3BitDouble()
        image.vVector = try objectReader.read3BitDouble()
        image.size = try objectReader.read2RawDouble()
        image.flags = try objectReader.readBitShort()
        image.clippingState = try objectReader.readBit()
        image.brightness = try Self.percentage(try objectReader.readByte())
        image.contrast = try Self.percentage(try objectReader.readByte())
        image.fade = try Self.percentage(try objectReader.readByte())

        if r2010Plus {
            // ClipMode: Inside = 1, Outside = 0
            image.clipMode = try objectReader.readBit() ? 1 : 0
        }

        switch try objectReader.readBitShort() {
        case 1: // Rectangular
            image.clipBoundaryVertices.append(try objectReader.read2RawDouble())
            image.clipBoundaryVertices.append(try objectReader.read2RawDouble())
        case 2: // Polygonal
            let nvertices = try objectReader.readBitLong()
            for _ in 0..<max(0, nvertices) {
                image.clipBoundaryVertices.append(try objectReader.read2RawDouble())
            }
        default: break
        }

        template.imgDefHandle = try handleReference()
        template.imgReactorHandle = try handleReference()
        return template
    }

    /// The Brightness / Contrast / Fade setters of images and underlays (0 … 100).
    private static func percentage(_ value: UInt8) throws -> UInt8 {
        if value > 100 { throw DwgError("Invalid Brightness value: \(value), must be in range 0-100") }
        return value
    }

    func readPdfUnderlay() throws -> ACad.CadTemplate? {
        let underlay = ACad.PdfUnderlay()
        let template = ACad.CadUnderlayTemplate(underlay)
        try readCommonEntityData(template)

        underlay.normal = try objectReader.read3BitDouble()
        underlay.insertPoint = try objectReader.read3BitDouble()
        underlay.rotation = try objectReader.readBitDouble()
        for (name, value) in [("XScale", try objectReader.readBitDouble()), ("YScale", try objectReader.readBitDouble()),
                              ("ZScale", try objectReader.readBitDouble())] {
            // The scale setters reject 0.
            if value == 0 { throw DwgError("\(name) value must be none zero. (Parameter '\(name)')\nActual value was 0.") }
            switch name {
            case "XScale": underlay.xScale = value
            case "YScale": underlay.yScale = value
            default: underlay.zScale = value
            }
        }
        underlay.flags = try objectReader.readByte()
        underlay.contrast = try Self.percentage(try objectReader.readByte())
        underlay.fade = try Self.percentage(try objectReader.readByte())

        template.definitionHandle = try handleReference()

        let nvertices = try mergedReaders.readBitLong()
        for _ in 0..<max(0, nvertices) {
            underlay.clipBoundaryVertices.append(try mergedReaders.read2RawDouble())
        }
        return template
    }

    func readOle2Frame() throws -> ACad.CadTemplate? {
        let ole2Frame = ACad.Ole2Frame()
        let template = ACad.CadOle2FrameTemplate(ole2Frame)
        try readCommonEntityData(template)

        // Flags BS 70
        ole2Frame.version = try mergedReaders.readBitShort()
        // R2000 +: Mode BS
        if r2000Plus { _ = try mergedReaders.readBitShort() }
        // Data Length BL
        let dataLength = try mergedReaders.readBitLong()
        ole2Frame.binaryData = Data(try mergedReaders.readBytes(Int(dataLength)))
        // R2000 +: Unknown RC
        if r2000Plus { _ = try mergedReaders.readByte() }
        return template
    }

    // ───────────────────────── Mesh and modeler geometry ─────────────────────────

    func readMesh() throws -> ACad.CadTemplate? {
        let mesh = ACad.Mesh()
        let template = ACad.CadEntityTemplate(mesh)
        try readCommonEntityData(template)

        mesh.version = try objectReader.readBitShort()
        mesh.blendCrease = try objectReader.readBit()
        mesh.subdivisionLevel = try objectReader.readBitLong()

        let nvertices = try objectReader.readBitLong()
        for _ in 0..<max(0, nvertices) {
            mesh.vertices.append(try objectReader.read3BitDouble())
        }

        // Faces: the C# loop also advances its counter by each face size.
        let nfaces = try objectReader.readBitLong()
        var i: Int32 = 0
        while i < nfaces {
            let faceSize = try objectReader.readBitLong()
            guard faceSize >= 0 else { throw DwgError("Arithmetic operation resulted in an overflow.") }
            var face: [Int32] = []
            for _ in 0..<faceSize {
                face.append(try objectReader.readBitLong())
            }
            i &+= faceSize
            mesh.faces.append(face)
            i &+= 1
        }

        let nedges = try objectReader.readBitLong()
        for _ in 0..<max(0, nedges) {
            let start = try objectReader.readBitLong()
            let end = try objectReader.readBitLong()
            mesh.edges.append(ACad.Mesh.Edge(start: start, end: end))
        }

        let ncrease = try objectReader.readBitLong()
        for l in 0..<Int(max(0, ncrease)) {
            try Self.checkIndex(l, mesh.edges.count)
            mesh.edges[l].crease = try objectReader.readBitDouble()
        }

        // Unknown BL
        _ = try objectReader.readBitLong()
        return template
    }

    func readSolid3D() throws -> ACad.CadTemplate? {
        let template = ACad.CadModelerGeometryTemplate(ACad.Solid3D())
        _ = try readModelerGeometry(template)
        if r2007Plus {
            // H 350 History ID
            template.historyHandle = try mergedReaders.handleReference(0)
        }
        return template
    }

    func readModelerGeometry(_ template: ACad.CadModelerGeometryTemplate) throws -> ACad.CadTemplate? {
        try readCommonEntityData(template)

        if !r2013Plus {
            // ACIS Empty bit B X If 1, then no data follows
            if !(try mergedReaders.readBit()) {
                try readModelerGeometryData(template)
                return template
            }
        }
        // R2013+ with DS binary data: ACadSharp only lists the entity in `AcisDsEntities`, which nothing reads.

        // Wireframe data present B X. Wires and silhouettes are read to keep the stream position; the model does
        // not keep them (nothing Filee renders or writes uses them).
        if try mergedReaders.readBit() {
            if try mergedReaders.readBit() {
                // Point 3BD X
                _ = try objectReader.read3BitDouble()
            }
            // Num IsoLines BL X
            _ = try mergedReaders.readBitLong()
            if try mergedReaders.readBit() {
                let nWires = try mergedReaders.readBitLong()
                for _ in 0..<max(0, nWires) { try readWire() }
            }
            let nSilhouettes = try mergedReaders.readBitLong()
            for _ in 0..<max(0, nSilhouettes) {
                // VP id BLL, VP target 3BD, VP dir from target 3BD, VP up dir 3BD, VP perspective B
                _ = try mergedReaders.readBitLongLong()
                _ = try mergedReaders.read3BitDouble()
                _ = try mergedReaders.read3BitDouble()
                _ = try mergedReaders.read3BitDouble()
                _ = try mergedReaders.readBit()
                if try mergedReaders.readBit() {
                    let nWires = try mergedReaders.readBitLong()
                    for _ in 0..<max(0, nWires) { try readWire() }
                }
            }
            // ACIS Empty bit B X: if 0, acis data follows
            if !(try mergedReaders.readBit()) {
                try readModelerGeometryData(template)
                return template
            }
        }

        // R2007 +: Unknown BL
        if r2007Plus { _ = try mergedReaders.readBitLong() }
        return template
    }

    func readModelerGeometryData(_ template: ACad.CadModelerGeometryTemplate) throws {
        let geometry = template.cadObject as! ACad.ModelerGeometry
        // Unknown bit B X
        _ = try mergedReaders.readBit()
        // Version BS Can be 1 or 2.
        let version = try mergedReaders.readBitShort()
        switch version {
        case 1:
            // Blocks of character-swapped SAT text until a block size of 0.
            var data: [UInt8] = []
            var blockSize = try mergedReaders.readBitLong()
            while blockSize > 0 {
                data += try mergedReaders.readBytes(Int(blockSize)).map { $0 > 0x20 && $0 < 0x9F ? 0x9F - $0 : $0 }
                blockSize = try mergedReaders.readBitLong()
            }
            if !data.isEmpty { geometry.acisData = Data(data) }
        case 2:
            // No payload length: read up to the end of the object data and cut at the End-of-ACIS-data marker.
            let currentPos = mergedReaders.positionInBits()
            let endPos = objectInitialPos + Int(size) * 8
            let remainingBytes = Int(Int32(truncatingIfNeeded: (endPos - currentPos) / 8))
            if remainingBytes > 0 {
                geometry.acisData = Data(Self.trimAtAcisEnd(try mergedReaders.readBytes(remainingBytes)))
            }
        default:
            // `notify` goes to an event nobody subscribes to.
            break
        }
    }

    /// `AcisTextCodec.TrimAtAcisEnd`: the payload up to and including its end marker (unchanged without one).
    static func trimAtAcisEnd(_ data: [UInt8]) -> [UInt8] {
        let markers: [[UInt8]] = [
            Array("End-of-ACIS-data".utf8),
            Array("End-of-ASM-data".utf8),
            [0x0E, 0x03] + Array("End".utf8) + [0x0E, 0x02] + Array("of".utf8) + [0x0E, 0x04] + Array("ACIS".utf8)
                + [0x0D, 0x04] + Array("data".utf8),
            [0x0E, 0x03] + Array("End".utf8) + [0x0E, 0x02] + Array("of".utf8) + [0x0E, 0x03] + Array("ASM".utf8)
                + [0x0D, 0x04] + Array("data".utf8),
        ]
        for marker in markers where data.count >= marker.count {
            for i in 0...(data.count - marker.count) where data[i..<(i + marker.count)].elementsEqual(marker) {
                return Array(data[..<(i + marker.count)])
            }
        }
        return data
    }

    /// `readWire`: read and discarded (see readModelerGeometry).
    func readWire() throws {
        // Wire type RC, selection marker BL
        _ = try mergedReaders.readByte()
        _ = try mergedReaders.readBitLong()
        // Wire color BS (`new Color(short)` validates the index)
        let color = try mergedReaders.readBitShort()
        _ = try ACad.Color.checked(index: color > 256 ? 256 : color)
        // Wire Acis Index BL
        _ = try mergedReaders.readBitLong()
        // Wire # of points BL (unsigned)
        let nPoints = UInt32(bitPattern: try mergedReaders.readBitLong())
        for _ in 0..<nPoints { _ = try mergedReaders.read3BitDouble() }
        // Transform present B X
        if try mergedReaders.readBit() {
            _ = try mergedReaders.read3BitDouble()
            _ = try mergedReaders.read3BitDouble()
            _ = try mergedReaders.read3BitDouble()
            _ = try mergedReaders.read3BitDouble()
            _ = try mergedReaders.readBitDouble()
            _ = try mergedReaders.readBit()
            _ = try mergedReaders.readBit()
            _ = try mergedReaders.readBit()
        }
    }

    // ───────────────────────── Proxies ─────────────────────────

    func readProxyEntity() throws -> ACad.CadTemplate? {
        let proxy = ACad.ProxyEntity()
        let template = ACad.CadEntityTemplate(proxy)
        try readCommonEntityData(template)
        try readCommonProxyData(proxy)
        return template
    }

    /// `readCommonProxyData(IProxy)` for ProxyEntity and ProxyObject.
    func readCommonProxyData(_ proxy: ACad.CadObject) throws {
        let entity = proxy as? ACad.ProxyEntity
        let object = proxy as? ACad.ProxyObject

        // Class ID BL 91
        let classId = try mergedReaders.readBitLong()
        if let dxfClass = classes[Int16(truncatingIfNeeded: classId)] {
            entity?.classNumber = Int32(dxfClass.classNumber)
            object?.dxfClass = dxfClass
        }

        guard r2000Plus else { return }
        if version > .ac1015 {
            // The string stream seems to contain the dxfsubclass
            _ = try mergedReaders.readVariableText()
        }

        let proxyVersion: ACad.Version
        let maintenanceVersion: Int32
        if !r2018Plus {
            // Object Drawing Format BL 95: version | maintenance version << 16
            let format = try mergedReaders.readBitLong()
            // shortcut: versions outside ACadVersion become Unknown (C# keeps the number); proxies are not rendered.
            proxyVersion = ACad.Version(rawValue: Int16(truncatingIfNeeded: format & 0xFFFF)) ?? .unknown
            maintenanceVersion = Int32(Int16(truncatingIfNeeded: format >> 16))
        } else {
            proxyVersion = ACad.Version(rawValue: Int16(truncatingIfNeeded: try mergedReaders.readBitLong())) ?? .unknown
            maintenanceVersion = try mergedReaders.readBitLong()
        }
        // Original Data Format B 70 0 for dwg, 1 for dxf
        let originalDataFormatDxf = try mergedReaders.readBit()

        if let entity {
            entity.version = proxyVersion
            entity.maintenanceVersion = maintenanceVersion
            entity.drawingFormat = Int32(proxyVersion.rawValue) | (maintenanceVersion << 16)
            entity.originalDataFormatDxf = originalDataFormatDxf
        }
        if let object {
            object.version = proxyVersion
            object.maintenanceVersion = maintenanceVersion
            object.originalDataFormatDxf = originalDataFormatDxf
        }
    }
}
