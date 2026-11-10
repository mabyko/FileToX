// Port of Filee.Engines/Cad/CadSceneBuilder.cs: turns a CAD document into a CadScene — walks model space (or the
// active layout when model space is empty), resolves layers, colours, line weights and line types, expands block
// references and converts every supported entity into geometry in WCS. Text and hatches live in the extension files
// next to this one.

import Foundation

/// Builds the display list of a drawing.
final class CadSceneBuilder {
    /// Primitive budget: beyond this a drawing is cut short rather than exhausting memory.
    static let maxPrimitives = 1_000_000

    /// Deepest block nesting followed (also stops self-referencing blocks).
    static let maxDepth = 16

    /// Largest MINSERT array expanded (rows × columns).
    static let maxArrayItems = 10_000

    /// Line weight used for "Default" (AutoCAD's LWDEFAULT is 0.25 mm; a thinner line reads better on screen).
    static let defaultLineWeightMm = 0.18

    /// Line weight 0 ("thinnest"), drawn as a fine line instead of a zero-width hairline.
    static let thinnestLineWeightMm = 0.1

    let scene = CadScene()
    private let lineTypeScale: Double
    private let pointsVisible: Bool
    private var visited = 0
    var patternSegments = 0

    private init(_ document: ACad.Document) {
        let header = document.header
        lineTypeScale = header.lineTypeScale > 0 && header.lineTypeScale.isFinite ? header.lineTypeScale : 1
        pointsVisible = header.pointDisplayMode != 1
    }

    /// Builds the scene of `document`: model space, or the active layout (paper space) when model space has nothing
    /// visible. Viewports are not followed. Throws `CancellationError` when the task is cancelled.
    static func build(_ document: ACad.Document) throws -> CadScene {
        let builder = CadSceneBuilder(document)
        try builder.drawEntities(Array(document.modelSpace.entities), .root)
        if builder.scene.items.isEmpty, let paper = document.blockRecords[ACad.BlockRecord.paperSpaceName] {
            builder.scene.space = paper.layout?.name ?? paper.name
            try builder.drawEntities(Array(paper.entities), .root)
        }
        return builder.scene
    }

    /// What the entities inside a block reference inherit from it: the transform to WCS, the insert's layer (entities
    /// on layer "0" take it over), and the colour, line weight and line type used by BYBLOCK.
    struct DrawContext {
        var transform: CadAffine3
        var insertLayer: ACad.Layer?
        var blockColor: CadColor
        var blockWidthMm: Double
        var blockLineType: ACad.LineType?
        var depth: Int

        /// Model space: BYBLOCK entities outside blocks are drawn like colour 7 (black on paper).
        static var root: DrawContext {
            DrawContext(transform: .identity, insertLayer: nil, blockColor: .black, blockWidthMm: CadSceneBuilder.defaultLineWeightMm,
                        blockLineType: nil, depth: 0)
        }
    }

    // ───────────────────────── Walking ─────────────────────────

    func drawEntities(_ entities: [ACad.Entity], _ context: DrawContext) throws {
        for entity in entities {
            visited += 1
            if visited & 1023 == 0 { try Task.checkCancellation() }
            if scene.truncated { return }
            if entity.isInvisible { continue }

            let layer = effectiveLayer(entity, context)
            do {
                if let insert = entity as? ACad.Insert {
                    try drawInsert(insert, layer, context)
                    continue
                }
                if !isShown(layer) { continue }
                try drawEntity(entity, layer, context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One broken entity (missing references, degenerate data) must not lose the whole drawing.
                skip(entity.objectName + " (invalid)")
            }
        }
    }

    private func drawEntity(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext) throws {
        switch entity {
        case let line as ACad.Line:
            stroke(entity, layer, context, figure2(context.transform.point(line.startPoint), context.transform.point(line.endPoint)))
        case let arc as ACad.Arc:
            drawArc(arc, layer, context)
        case let circle as ACad.Circle:
            drawCircle(circle, layer, context)
        case let ellipse as ACad.Ellipse:
            drawEllipse(ellipse, layer, context)
        case let polyline as ACad.LwPolyline:
            drawLwPolyline(polyline, layer, context)
        case let mesh as ACad.PolyfaceMesh:
            drawPolyfaceMesh(mesh, layer, context)
        case let mesh as ACad.PolygonMesh:
            drawPolygonMesh(mesh, layer, context)
        case let polyline as ACad.Polyline2D:
            drawPolyline2D(polyline, layer, context)
        case let polyline as ACad.Polyline3D:
            drawPolyline3D(polyline, layer, context)
        case let spline as ACad.Spline:
            drawSpline(spline, layer, context)
        case let definition as ACad.AttributeDefinition:
            // Inside blocks, definitions are replaced by the insert's attributes; alone they show their tag.
            if context.depth == 0 { drawText(definition, definition.tag, layer, context) }
        case let text as ACad.TextEntity:
            if !(text is ACad.AttributeEntity) || (text as! ACad.AttributeEntity).flags & ACad.AttributeFlags.hidden == 0 {
                drawText(text, text.value, layer, context)
            }
        case let mtext as ACad.MText:
            drawMText(mtext, layer, context)
        case let dimension as ACad.Dimension:
            try drawDimension(dimension, layer, context)
        case let leader as ACad.Leader:
            drawLeader(leader, layer, context)
        case let multiLeader as ACad.MultiLeader:
            try drawMultiLeader(multiLeader, layer, context)
        case let hatch as ACad.Hatch:
            drawHatch(hatch, layer, context)
        case let solid as ACad.Solid:
            drawSolid(solid, layer, context)
        case let face as ACad.Face3D:
            drawFace(face, layer, context)
        case let point as ACad.Point:
            if pointsVisible {
                add(CadPointPrimitive(location: context.transform.point(point.location), color: resolveColor(entity, layer, context),
                                      widthMm: resolveWidth(entity, layer, context)),
                    context.transform.point(point.location))
            }
        case let xline as ACad.XLine:
            drawInfinite(entity, layer, context, CadVec3(xline.firstPoint), CadVec3(xline.direction), isRay: false)
        case let ray as ACad.Ray:
            drawInfinite(entity, layer, context, CadVec3(ray.startPoint), CadVec3(ray.direction), isRay: true)
        case let mline as ACad.MLine:
            drawMLine(mline, layer, context)
        case let mesh as ACad.Mesh:
            drawMesh(mesh, layer, context)
        case is ACad.Viewport:
            break // layout viewports show model space through a view: not followed
        case is ACad.Seqend:
            break // end marker of old-style polylines and attributes, nothing to draw
        default:
            skip(entity.objectName)
        }
    }

    // ───────────────────────── Blocks ─────────────────────────

    private func drawInsert(_ insert: ACad.Insert, _ layer: ACad.Layer, _ context: DrawContext) throws {
        // A frozen layer hides the whole reference; an OFF (or non-plotting) layer only hides what inherits it, i.e.
        // the block's entities on layer "0" (that is how AutoCAD shows it).
        if isFrozen(layer) { return }
        guard let block = insert.block else {
            skip("INSERT (missing block)")
            return
        }
        if context.depth >= CadSceneBuilder.maxDepth {
            scene.truncated = true
            return
        }

        let inherited = inherit(insert, layer, context)
        let basePoint = CadVec3(block.blockEntity.basePoint)
        var columns = max(1, Int(insert.columnCount))
        var rows = max(1, Int(insert.rowCount))
        if columns * rows > CadSceneBuilder.maxArrayItems {
            scene.truncated = true
            columns = min(columns, CadSceneBuilder.maxArrayItems)
            rows = max(1, min(rows, CadSceneBuilder.maxArrayItems / columns))
        }

        let placement = context.transform
            .multiply(.ocs(insert.normal))
            .multiply(.translation(CadVec3(insert.insertPoint)))
            .multiply(.rotationZ(insert.rotation))
        let scale = CadAffine3.scale(insert.xScale, insert.yScale, insert.zScale)
            .multiply(.translation(CadVec3(-basePoint.x, -basePoint.y, -basePoint.z)))

        let entities = Array(block.entities)
        var row = 0
        while row < rows && !scene.truncated {
            var column = 0
            while column < columns && !scene.truncated {
                let cell = placement
                    .multiply(.translation(CadVec3(Double(column) * insert.columnSpacing, Double(row) * insert.rowSpacing, 0)))
                    .multiply(scale)
                var cellContext = inherited
                cellContext.transform = cell
                try drawEntities(entities, cellContext)
                column += 1
            }
            row += 1
        }

        // Attributes belong to the reference, not the block: they are positioned in the parent's coordinates, but
        // like the block's contents they take over the insert's layer when on layer "0" and its BYBLOCK properties.
        var attributeContext = inherited
        attributeContext.transform = context.transform
        attributeContext.depth = context.depth
        for attribute in insert.attributes {
            let attributeLayer = effectiveLayer(attribute, attributeContext)
            if !attribute.isInvisible && isShown(attributeLayer) {
                try drawEntity(attribute, attributeLayer, attributeContext)
            }
        }
    }

    /// The context for the contents of a block reference, dimension or multileader block.
    private func inherit(_ reference: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext) -> DrawContext {
        var inherited = context
        inherited.insertLayer = layer
        inherited.blockColor = resolveColor(reference, layer, context)
        inherited.blockWidthMm = resolveWidth(reference, layer, context)
        inherited.blockLineType = resolveLineType(reference, layer, context)
        inherited.depth = context.depth + 1
        return inherited
    }

    private func drawDimension(_ dimension: ACad.Dimension, _ layer: ACad.Layer, _ context: DrawContext) throws {
        var block = dimension.block
        if block == nil || block!.entities.isEmpty {
            // Some writers omit the dimension picture; let the model generate one from the definition points.
            do {
                try dimension.updateBlock()
                block = dimension.block
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                block = nil
            }
        }
        guard let block, !block.entities.isEmpty else {
            skip("DIMENSION (no block)")
            return
        }
        if context.depth >= CadSceneBuilder.maxDepth { return }

        // The picture is stored in drawing coordinates (each entity carries its own extrusion), so it is drawn in
        // place, like ezdxf does; only colour, layer and line properties come from the dimension (BYBLOCK).
        try drawEntities(Array(block.entities), inherit(dimension, layer, context))
    }

    // ───────────────────────── Curves ─────────────────────────

    private func drawArc(_ arc: ACad.Arc, _ layer: ACad.Layer, _ context: DrawContext) {
        let m = context.transform.multiply(.ocs(arc.normal))
        let start = arc.startAngle
        var end = arc.endAngle
        while end <= start { end += 2 * Double.pi }
        let figure = CadSceneBuilder.arcFigure(m, CadVec3(arc.center), arc.radius, arc.radius, start, end)
        stroke(arc, layer, context, figure)
    }

    private func drawCircle(_ circle: ACad.Circle, _ layer: ACad.Layer, _ context: DrawContext) {
        let m = context.transform.multiply(.ocs(circle.normal))
        let figure = CadSceneBuilder.arcFigure(m, CadVec3(circle.center), circle.radius, circle.radius, 0, 2 * Double.pi)
        figure.closed = true
        stroke(circle, layer, context, figure)
    }

    private func drawEllipse(_ ellipse: ACad.Ellipse, _ layer: ACad.Layer, _ context: DrawContext) {
        // ELLIPSE is in WCS: the minor axis is the major axis turned by 90° around the normal.
        let major = CadVec3(ellipse.majorAxisEndPoint)
        let minor = CadVec3.cross(CadVec3(ellipse.normal).normalized(), major) * ellipse.radiusRatio
        let start = ellipse.startParameter
        var end = ellipse.endParameter
        while end <= start { end += 2 * Double.pi }
        let m = context.transform
        let center = m.point(ellipse.center)
        let u = m.vector(major)
        let v = m.vector(minor)
        let figure = CadFigure(center + u * cos(start) + v * sin(start))
        figure.arcTo(center, u, v, start, end)
        figure.closed = abs(end - start - 2 * Double.pi) < 1e-9
        stroke(ellipse, layer, context, figure)
    }

    /// An arc of the circle/ellipse with radii `rx`, `ry` in `m`'s plane.
    static func arcFigure(_ m: CadAffine3, _ center: CadVec3, _ rx: Double, _ ry: Double, _ start: Double, _ end: Double) -> CadFigure {
        let c = m.point(center)
        let u = m.vector(rx, 0)
        let v = m.vector(0, ry)
        let figure = CadFigure(c + u * cos(start) + v * sin(start))
        figure.arcTo(c, u, v, start, end)
        return figure
    }

    private func drawSpline(_ spline: ACad.Spline, _ layer: ACad.Layer, _ context: DrawContext) {
        let points: [CadVec3]
        if spline.controlPoints.count >= 2 {
            let weights = spline.weights.count == spline.controlPoints.count ? spline.weights : nil
            points = CadCurves.sampleNurbs(Int(spline.degree), spline.controlPoints.map(CadVec3.init), spline.knots, weights)
        } else {
            points = CadCurves.throughPoints(spline.fitPoints.map(CadVec3.init), closed: spline.flags & ACad.SplineFlags.closed != 0)
        }
        if points.count >= 2 { stroke(spline, layer, context, CadSceneBuilder.polylineFigure(context.transform, points, closed: false)) }
    }

    static func polylineFigure(_ m: CadAffine3, _ points: [CadVec3], closed: Bool) -> CadFigure {
        let figure = CadFigure(m.point(points[0]))
        for point in points.dropFirst() { figure.lineTo(m.point(point)) }
        figure.closed = closed
        return figure
    }

    private func figure2(_ a: CadVec2, _ b: CadVec2) -> CadFigure {
        let figure = CadFigure(a)
        figure.lineTo(b)
        return figure
    }

    // ───────────────────────── Polylines ─────────────────────────

    /// A polyline vertex in the entity's OCS with the width at the start and end of the following segment.
    struct PolyVertex {
        var location: CadVec2
        var bulge: Double
        var startWidth: Double
        var endWidth: Double
    }

    private func drawLwPolyline(_ polyline: ACad.LwPolyline, _ layer: ACad.Layer, _ context: DrawContext) {
        if polyline.vertices.isEmpty { return }
        let constant = polyline.constantWidth
        let vertices = polyline.vertices.map { v in
            PolyVertex(location: CadVec2(v.location.x, v.location.y), bulge: v.bulge,
                       startWidth: v.startWidth > 0 || v.endWidth > 0 ? v.startWidth : constant,
                       endWidth: v.startWidth > 0 || v.endWidth > 0 ? v.endWidth : constant)
        }
        let m = context.transform.multiply(.ocs(polyline.normal)).multiply(.translation(CadVec3(0, 0, polyline.elevation)))
        drawPolyline(polyline, layer, context, m, vertices, polyline.isClosed)
    }

    private func drawPolyline2D(_ polyline: ACad.Polyline2D, _ layer: ACad.Layer, _ context: DrawContext) {
        // R12 files can give meshes as plain polylines whose face records look like vertices at the origin.
        if polyline.flags & (ACad.PolylineFlags.polyfaceMesh | ACad.PolylineFlags.polygonMesh) != 0 {
            skip(polyline.objectName + " (mesh)")
            return
        }
        let smoothed = polyline.flags & ACad.PolylineFlags.splineFit != 0
        // Spline-fit polylines keep their frame (control points) next to the fitted vertices: draw the fit.
        let list = polyline.vertices.filter { !(smoothed && $0.flags & ACad.VertexFlags.splineFrameControlPoint != 0) }
        if list.isEmpty { return }
        let anyVertexWidth = list.contains { $0.startWidth > 0 || $0.endWidth > 0 }
        let vertices = list.map { v in
            PolyVertex(location: CadVec2(v.location.x, v.location.y), bulge: smoothed ? 0 : v.bulge,
                       startWidth: anyVertexWidth ? v.startWidth : polyline.startWidth,
                       endWidth: anyVertexWidth ? v.endWidth : polyline.endWidth)
        }
        let m = context.transform.multiply(.ocs(polyline.normal)).multiply(.translation(CadVec3(0, 0, polyline.elevation)))
        drawPolyline(polyline, layer, context, m, vertices, polyline.isClosed)
    }

    private func drawPolyline3D(_ polyline: ACad.Polyline3D, _ layer: ACad.Layer, _ context: DrawContext) {
        if polyline.flags & (ACad.PolylineFlags.polyfaceMesh | ACad.PolylineFlags.polygonMesh) != 0 {
            skip(polyline.objectName + " (mesh)")
            return
        }
        let smoothed = polyline.flags & ACad.PolylineFlags.splineFit != 0
        var points = polyline.vertices
            .filter { !(smoothed && $0.flags & ACad.VertexFlags.splineFrameControlPoint != 0) }
            .map { CadVec3($0.location) }
        if points.isEmpty { return }
        if points.count == 1 { points.append(points[0]) }
        stroke(polyline, layer, context, CadSceneBuilder.polylineFigure(context.transform, points, closed: polyline.isClosed))
    }

    /// Draws a 2D polyline in plane `m`. Thin polylines become one stroked figure with bulge arcs; a constant width
    /// becomes a wide stroke; varying widths (arrows, tapers) become filled bands.
    private func drawPolyline(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext, _ m: CadAffine3,
                              _ vertices: [PolyVertex], _ closed: Bool) {
        let segmentCount = closed ? vertices.count : vertices.count - 1
        let figure = CadFigure(m.point(vertices[0].location.x, vertices[0].location.y))
        if segmentCount <= 0 {
            figure.lineTo(figure.start) // a single vertex shows as a dot
            stroke(entity, layer, context, figure)
            return
        }

        let widths = (0..<segmentCount).map { (vertices[$0].startWidth, vertices[$0].endWidth) }
        let constant = widths[0].0
        let isConstant = widths.allSatisfy { abs($0.0 - constant) < 1e-12 && abs($0.1 - constant) < 1e-12 }

        if isConstant || widths.allSatisfy({ $0.0 <= 0 && $0.1 <= 0 }) {
            for i in 0..<segmentCount {
                CadSceneBuilder.appendSegment(figure, m, vertices[i], vertices[(i + 1) % vertices.count])
            }
            figure.closed = closed
            stroke(entity, layer, context, figure, constant > 0 ? constant * m.planScale : 0)
            return
        }

        // Varying widths: each wide segment is a filled band, zero-width segments stay thin lines.
        let color = resolveColor(entity, layer, context)
        for i in 0..<segmentCount {
            let a = vertices[i]
            let b = vertices[(i + 1) % vertices.count]
            if a.startWidth <= 0 && a.endWidth <= 0 {
                let thin = CadFigure(m.point(a.location.x, a.location.y))
                CadSceneBuilder.appendSegment(thin, m, a, b)
                stroke(entity, layer, context, thin)
                continue
            }
            let band = CadFillPrimitive(color: color)
            band.figures.append(CadSceneBuilder.band(m, a, b))
            addFill(band)
        }
    }

    static func appendSegment(_ figure: CadFigure, _ m: CadAffine3, _ a: PolyVertex, _ b: PolyVertex) {
        let end = m.point(b.location.x, b.location.y)
        if abs(a.bulge) < 1e-10 || (b.location - a.location).length < 1e-12 {
            figure.lineTo(end)
            return
        }
        let arc = CadCurves.bulgeArc(a.location, b.location, a.bulge)
        figure.arcTo(m.point(arc.center.x, arc.center.y), m.vector(arc.radius, 0), m.vector(0, arc.radius), arc.startAngle,
                     arc.startAngle + arc.sweep)
    }

    /// The outline of a wide polyline segment whose width changes linearly from start to end.
    private static func band(_ m: CadAffine3, _ a: PolyVertex, _ b: PolyVertex) -> CadFigure {
        var left: [CadVec2] = []
        var right: [CadVec2] = []
        if abs(a.bulge) < 1e-10 {
            let normal = (b.location - a.location).normalized().perp
            left.append(a.location + normal * (a.startWidth / 2))
            left.append(b.location + normal * (a.endWidth / 2))
            right.append(a.location - normal * (a.startWidth / 2))
            right.append(b.location - normal * (a.endWidth / 2))
        } else {
            let arc = CadCurves.bulgeArc(a.location, b.location, a.bulge)
            let steps = max(4, CadMath.int((abs(arc.sweep) / (Double.pi / 18)).rounded(.up)))
            for s in 0...steps {
                let f = Double(s) / Double(steps)
                let angle = arc.startAngle + arc.sweep * f
                let half = (a.startWidth + (a.endWidth - a.startWidth) * f) / 2
                let direction = CadVec2(cos(angle), sin(angle))
                left.append(arc.center + direction * (arc.radius + half))
                right.append(arc.center + direction * max(arc.radius - half, 0))
            }
        }
        let figure = CadFigure(m.point(left[0].x, left[0].y))
        for p in left.dropFirst() { figure.lineTo(m.point(p.x, p.y)) }
        for p in right.reversed() { figure.lineTo(m.point(p.x, p.y)) }
        figure.closed = true
        return figure
    }

    private func drawPolyfaceMesh(_ mesh: ACad.PolyfaceMesh, _ layer: ACad.Layer, _ context: DrawContext) {
        let vertices = mesh.vertices.map { CadVec3($0.location) }
        let edges = StrokeCollector(self, mesh, layer, context)
        for face in mesh.faces {
            let indices = [face.index1, face.index2, face.index3, face.index4].filter { $0 != 0 }.map(Int.init)
            for i in indices.indices {
                let from = indices[i]
                let to = indices[(i + 1) % indices.count]
                // A negative index hides the edge that starts at that vertex.
                if from < 0 || abs(from) > vertices.count || abs(to) > vertices.count { continue }
                edges.line(vertices[from - 1], vertices[abs(to) - 1])
            }
        }
        edges.flush()
    }

    private func drawPolygonMesh(_ mesh: ACad.PolygonMesh, _ layer: ACad.Layer, _ context: DrawContext) {
        let vertices = mesh.vertices.map { CadVec3($0.location) }
        let m = Int(mesh.mVertexCount), n = Int(mesh.nVertexCount)
        if m <= 0 || n <= 0 || m * n > vertices.count {
            skip(mesh.objectName)
            return
        }
        let edges = StrokeCollector(self, mesh, layer, context)
        for i in 0..<m {
            for j in 0..<n {
                if j + 1 < n { edges.line(vertices[i * n + j], vertices[i * n + j + 1]) }
                if i + 1 < m { edges.line(vertices[i * n + j], vertices[(i + 1) * n + j]) }
            }
        }
        edges.flush()
    }

    private func drawMesh(_ mesh: ACad.Mesh, _ layer: ACad.Layer, _ context: DrawContext) {
        let vertices = mesh.vertices.map(CadVec3.init)
        let edges = StrokeCollector(self, mesh, layer, context)
        for face in mesh.faces {
            for i in face.indices {
                let a = Int(face[i]), b = Int(face[(i + 1) % face.count])
                if a >= 0 && b >= 0 && a < vertices.count && b < vertices.count { edges.line(vertices[a], vertices[b]) }
            }
        }
        edges.flush()
    }

    private func drawMLine(_ mline: ACad.MLine, _ layer: ACad.Layer, _ context: DrawContext) {
        // Each element of the multiline style is a polyline through the vertices, offset along their miters.
        let elements = mline.vertices.isEmpty ? 0 : mline.vertices.map(\.segments.count).max()!
        for element in 0..<elements {
            let points = mline.vertices
                .filter { element < $0.segments.count && !$0.segments[element].parameters.isEmpty }
                .map { CadVec3($0.position) + CadVec3($0.miter) * $0.segments[element].parameters[0] }
            if points.count >= 2 {
                stroke(mline, layer, context, CadSceneBuilder.polylineFigure(context.transform, points, closed: mline.flags & ACad.MLineFlags.closed != 0))
            }
        }
    }

    // ───────────────────────── Other entities ─────────────────────────

    private func drawSolid(_ solid: ACad.Solid, _ layer: ACad.Layer, _ context: DrawContext) {
        // SOLID / TRACE corners are ordered 1-2-4-3 around the outline; a triangle repeats its third corner.
        let m = context.transform.multiply(.ocs(solid.normal))
        let figure = CadFigure(m.point(solid.firstCorner))
        figure.lineTo(m.point(solid.secondCorner))
        figure.lineTo(m.point(solid.fourthCorner))
        figure.lineTo(m.point(solid.thirdCorner))
        figure.closed = true
        let fill = CadFillPrimitive(color: resolveColor(solid, layer, context))
        fill.figures.append(figure)
        addFill(fill)
    }

    private func drawFace(_ face: ACad.Face3D, _ layer: ACad.Layer, _ context: DrawContext) {
        let corners = [face.firstCorner, face.secondCorner, face.thirdCorner, face.fourthCorner].map(CadVec3.init)
        let hidden = [ACad.InvisibleEdgeFlags.first, ACad.InvisibleEdgeFlags.second, ACad.InvisibleEdgeFlags.third, ACad.InvisibleEdgeFlags.fourth]
        let edges = StrokeCollector(self, face, layer, context)
        for i in 0..<4 where face.flags & hidden[i] == 0 {
            edges.line(corners[i], corners[(i + 1) % 4])
        }
        edges.flush()
    }

    private func drawInfinite(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext, _ origin: CadVec3,
                              _ direction: CadVec3, isRay: Bool) {
        let o = context.transform.point(origin)
        let d = context.transform.vector(direction)
        if d.length < 1e-12 { return }
        add(CadInfiniteLinePrimitive(origin: o, direction: d.normalized(), isRay: isRay, color: resolveColor(entity, layer, context),
                                     widthMm: resolveWidth(entity, layer, context),
                                     dashes: resolveDashes(entity, layer, context, context.transform)),
            o)
    }

    private func drawLeader(_ leader: ACad.Leader, _ layer: ACad.Layer, _ context: DrawContext) {
        let points = leader.vertices.map(CadVec3.init)
        if points.count < 2 { return }
        let path = leader.pathType == 1 ? CadCurves.throughPoints(points, closed: false) : points
        stroke(leader, layer, context, CadSceneBuilder.polylineFigure(context.transform, path, closed: false))
        if leader.arrowHeadEnabled {
            let style = leader.style
            let size = style.arrowSize * (style.scaleFactor > 0 ? style.scaleFactor : 1)
            arrow(leader, layer, context, points[0], points[1], size)
        }
    }

    private func drawMultiLeader(_ leader: ACad.MultiLeader, _ layer: ACad.Layer, _ context: DrawContext) throws {
        let data = leader.contextData
        var lineContext = context
        lineContext.blockColor = resolveColor(leader, layer, context)
        let lineColor = resolveColor(leader.lineColor, layer, lineContext)
        let arrowSize = data.arrowheadSize > 0 ? data.arrowheadSize : leader.arrowheadSize * (leader.scaleFactor > 0 ? leader.scaleFactor : 1)
        let width = resolveWidth(leader, layer, context)
        for root in data.leaderRoots {
            for line in root.lines {
                var points = line.points.map(CadVec3.init)
                points.append(CadVec3(root.connectionPoint))
                if points.count < 2 { continue }
                addStroke(CadStrokePrimitive(color: lineColor, widthMm: width), CadSceneBuilder.polylineFigure(context.transform, points, closed: false))
                if arrowSize > 0 { arrowPrimitive(lineColor, context, points[0], points[1], arrowSize) }
            }
            if leader.enableLanding && root.landingDistance > 0 {
                let start = CadVec3(root.connectionPoint)
                let end = start + CadVec3(root.direction).normalized() * root.landingDistance
                addStroke(CadStrokePrimitive(color: lineColor, widthMm: width), figure2(context.transform.point(start), context.transform.point(end)))
            }
        }

        if data.hasTextContents && !data.textLabel.isEmpty {
            let textColor = resolveColor(data.textColor, layer, lineContext)
            let attachment: Int16 = switch data.textAttachmentPoint {
            case 2: ACad.AttachmentPoint.topCenter // TextAttachmentPointType.Center
            case 3: ACad.AttachmentPoint.topRight // TextAttachmentPointType.Right
            default: ACad.AttachmentPoint.topLeft
            }
            let height = data.textHeight > 0 ? data.textHeight : 2.5
            drawMTextCore(data.textLabel, CadVec3(data.textLocation), CadVec3(data.direction), CadVec3(data.textNormal), height,
                          data.boundaryWidth, attachment, data.lineSpacingFactor, data.textStyle ?? leader.textStyle, textColor, context)
        } else if data.hasContentsBlock, let block = data.blockContent, context.depth < CadSceneBuilder.maxDepth {
            let scale = data.blockContentScale
            let basePoint = block.blockEntity.basePoint
            let transform = context.transform
                .multiply(.ocs(data.blockContentNormal))
                .multiply(.translation(CadVec3(data.blockContentLocation)))
                .multiply(.rotationZ(data.blockContentRotation))
                .multiply(.scale(scale.x == 0 ? 1 : scale.x, scale.y == 0 ? 1 : scale.y, scale.z == 0 ? 1 : scale.z))
                .multiply(.translation(CadVec3(-basePoint.x, -basePoint.y, -basePoint.z)))
            var blockContext = inherit(leader, layer, context)
            blockContext.transform = transform
            try drawEntities(Array(block.entities), blockContext)
        }
    }

    /// A filled closed arrowhead at `tip` pointing away from `from`.
    private func arrow(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext, _ tip: CadVec3, _ from: CadVec3, _ size: Double) {
        arrowPrimitive(resolveColor(entity, layer, context), context, tip, from, size)
    }

    private func arrowPrimitive(_ color: CadColor, _ context: DrawContext, _ tip: CadVec3, _ from: CadVec3, _ size: Double) {
        let direction = tip - from
        let length = direction.length
        if size <= 0 || length < 1e-12 { return }
        let d = direction * (1 / length)
        let side = CadVec3.cross(CadVec3(0, 0, 1), d).normalized() * (size / 6)
        let back = tip - d * size
        let m = context.transform
        let figure = CadFigure(m.point(tip))
        figure.lineTo(m.point(back + side))
        figure.lineTo(m.point(back - side))
        figure.closed = true
        let fill = CadFillPrimitive(color: color)
        fill.figures.append(figure)
        addFill(fill)
    }

    // ───────────────────────── Properties ─────────────────────────

    /// Entities on layer "0" inside a block take on the layer of the block reference.
    func effectiveLayer(_ entity: ACad.Entity, _ context: DrawContext) -> ACad.Layer {
        let layer = entity.layer
        if let insertLayer = context.insertLayer, layer.name == ACad.Layer.defaultName { return insertLayer }
        return layer
    }

    /// Visible on a plot: on, thawed and plottable (the Defpoints layer never plots).
    func isShown(_ layer: ACad.Layer) -> Bool { layer.isOn && !isFrozen(layer) && layer.plotFlag }

    private func isFrozen(_ layer: ACad.Layer) -> Bool { layer.flags & ACad.LayerFlags.frozen != 0 }

    func resolveColor(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext) -> CadColor {
        resolveColor(entity.color, layer, context)
    }

    /// BYLAYER / BYBLOCK resolution, ACI index or true colour to RGB. White and near-white (ACI 7 draws white on
    /// AutoCAD's black screen) become black, because the page is white.
    func resolveColor(_ color: ACad.Color, _ layer: ACad.Layer, _ context: DrawContext) -> CadColor {
        if color.isByBlock { return context.blockColor }
        var color = color
        if color.isByLayer { color = layer.color }
        if color.isByLayer || color.isByBlock || color.index == 257 { return .black }
        let (r, g, b) = color.rgb
        if min(r, min(g, b)) >= 224 { return .black }
        return CadColor(r: r, g: g, b: b)
    }

    func resolveWidth(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext) -> Double {
        switch entity.lineWeight {
        case .byLayer: return widthOf(layer.lineWeight, context)
        case .byBlock: return context.blockWidthMm
        default: return widthOf(entity.lineWeight, context)
        }
    }

    private func widthOf(_ weight: ACad.LineWeight, _ context: DrawContext) -> Double {
        if weight == .byBlock { return context.blockWidthMm }
        if weight == .w0 { return CadSceneBuilder.thinnestLineWeightMm }
        if weight.rawValue > 0 && weight.rawValue <= ACad.LineWeight.w211.rawValue {
            return max(Double(weight.rawValue) / 100.0, CadSceneBuilder.thinnestLineWeightMm)
        }
        return CadSceneBuilder.defaultLineWeightMm // Default, ByLayer on a layer, ByDIPs
    }

    private func resolveLineType(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext) -> ACad.LineType? {
        let type = entity.lineType
        if type.name.caseInsensitiveCompare(ACad.LineType.byLayerName) == .orderedSame { return layer.lineType }
        if type.name.caseInsensitiveCompare(ACad.LineType.byBlockName) == .orderedSame { return context.blockLineType }
        return type
    }

    /// The entity's dash pattern in drawing units: line type segments × LTSCALE × the entity's scale × the block
    /// scale. Shapes and text inside complex line types are left out (their space stays empty).
    func resolveDashes(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext, _ m: CadAffine3) -> [Double]? {
        guard let type = resolveLineType(entity, layer, context), type.isComplex else { return nil }
        let segments = type.segments.map(\.length)
        if segments.count < 2 || segments.allSatisfy({ $0 >= 0 }) || segments.contains(where: { !$0.isFinite }) { return nil }
        let entityScale = entity.lineTypeScale > 0 && entity.lineTypeScale.isFinite ? entity.lineTypeScale : 1
        let scale = lineTypeScale * entityScale * m.planScale
        if !(scale > 0) || segments.reduce(0, { $0 + abs($1) }) * scale <= 0 { return nil }
        return segments.map { $0 * scale }
    }

    // ───────────────────────── Output ─────────────────────────

    func stroke(_ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext, _ figure: CadFigure, _ worldWidth: Double = 0) {
        addStroke(CadStrokePrimitive(color: resolveColor(entity, layer, context), widthMm: resolveWidth(entity, layer, context),
                                     worldWidth: worldWidth, dashes: resolveDashes(entity, layer, context, context.transform)),
                  figure)
    }

    private func addStroke(_ primitive: CadStrokePrimitive, _ figure: CadFigure) {
        primitive.figures.append(figure)
        if reserve() {
            figure.add(to: &scene.extents)
            scene.items.append(primitive)
        }
    }

    func addFill(_ fill: CadFillPrimitive) {
        if !reserve() { return }
        for figure in fill.figures { figure.add(to: &scene.extents) }
        scene.items.append(fill)
    }

    private func add(_ primitive: CadScenePrimitive, _ extentPoint: CadVec2) {
        if !reserve() { return }
        scene.extents.add(extentPoint)
        scene.items.append(primitive)
    }

    func reserve() -> Bool {
        if scene.items.count < CadSceneBuilder.maxPrimitives { return true }
        scene.truncated = true
        return false
    }

    func skip(_ type: String) { scene.skipped[type, default: 0] += 1 }

    /// Collects the edges of a mesh or face into one stroke.
    private final class StrokeCollector {
        private let builder: CadSceneBuilder
        private let entity: ACad.Entity
        private let layer: ACad.Layer
        private let context: DrawContext
        private var figures: [CadFigure] = []

        init(_ builder: CadSceneBuilder, _ entity: ACad.Entity, _ layer: ACad.Layer, _ context: DrawContext) {
            self.builder = builder
            self.entity = entity
            self.layer = layer
            self.context = context
        }

        func line(_ a: CadVec3, _ b: CadVec3) { figures.append(builder.figure2(context.transform.point(a), context.transform.point(b))) }

        func flush() {
            if figures.isEmpty || !builder.reserve() { return }
            let primitive = CadStrokePrimitive(color: builder.resolveColor(entity, layer, context),
                                               widthMm: builder.resolveWidth(entity, layer, context),
                                               dashes: builder.resolveDashes(entity, layer, context, context.transform))
            for figure in figures {
                figure.add(to: &builder.scene.extents)
                primitive.figures.append(figure)
            }
            builder.scene.items.append(primitive)
        }
    }
}

/// .NET numeric conversions the CAD port relies on.
enum CadMath {
    /// `(int)value` on .NET 9+: truncation with saturation, NaN → 0 (Swift's `Int(_:)` would trap).
    static func int(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int(Int32.max) }
        if value <= Double(Int32.min) { return Int(Int32.min) }
        return Int(value)
    }
}
