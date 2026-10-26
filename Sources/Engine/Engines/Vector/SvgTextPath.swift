// Geometry for SVG text on a path (SVG 2 §11.5.2 "Position on path"): the path a ‘textPath’ refers to, measured by
// length, so SvgNormalizer can place each typographic character at the midpoint of its advance along the path and turn
// it with the path's tangent. CoreSVG draws textPath content as straight text at the origin.

import CoreGraphics
import Foundation

extension SvgNormalizer {
    /// What a ‘textPath’ lays its characters on.
    enum TextPathReference {
        /// A usable path.
        case shape(TextPathShape)
        /// A missing or invalid reference: the characters on it are not rendered.
        case invalid
        /// A reference the normalizer doesn't measure (percentage geometry, or past the drawing's flattening budget):
        /// the text stays with CoreSVG.
        case unsupported
    }

    /// Ids of a drawing with text on a path, and how many more path pieces its text may flatten. The budget bounds the
    /// memory and time a huge path, or many texts on one, can take; past it, text on a path stays with CoreSVG.
    final class TextPathTargets {
        struct Key: Hashable {
            let element: ObjectIdentifier
            let fontSize: Double
        }

        let ids: [String: XElement]
        var remainingPieces = 1 << 22
        /// Referenced geometry, parsed once: its segments with the element's transform and their piece count, or nil
        /// when it isn't measured.
        var parsed: [Key: (segments: [PathSegment], pieces: Int)?] = [:]

        init(_ ids: [String: XElement]) { self.ids = ids }
    }

    /// A path flattened into line pieces, with its start offset resolved.
    final class TextPathShape {
        private struct Piece {
            var from: CGPoint, to: CGPoint
            var start: Double, length: Double
        }

        private var pieces: [Piece] = []
        private(set) var length = 0.0
        /// A single closed subpath, where characters past the end wrap around (SVG 2 closed-path rules).
        let closed: Bool
        /// Where text after the ‘textPath’ continues.
        let end: CGPoint
        /// ‘startOffset’ in user units.
        var offset = 0.0

        /// How many straight pieces flattening `segments` takes.
        static func pieces(_ segments: [PathSegment]) -> Int {
            var count = 0, current = CGPoint.zero, start = CGPoint.zero
            for segment in segments {
                switch segment {
                case .move(let point): current = point; start = point
                case .line(let point): count += 1; current = point
                case .quad(let control, let point): count += pieces(current.distance(to: control) + control.distance(to: point)); current = point
                case .cubic(let c1, let c2, let point): count += pieces(current.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: point)); current = point
                case .close: count += 1; current = start
                }
            }
            return count
        }

        /// A curve becomes at least 64 pieces, and more for long ones (by their control polygon), so glyph positions and
        /// angles stay smooth at large scales.
        private static func pieces(_ controlLength: CGFloat) -> Int {
            controlLength.isFinite ? Int(min(max((controlLength * 2).rounded(.up), 64), 4096)) : 64
        }

        fileprivate init?(_ segments: [PathSegment], reversed: Bool) {
            var lines: [(CGPoint, CGPoint)] = []
            var current = CGPoint.zero, subpathStart = CGPoint.zero
            var subpaths = 0, lastClosed = false
            for segment in segments {
                if case .close = segment {} else { lastClosed = false }
                switch segment {
                case .move(let point):
                    current = point; subpathStart = point; subpaths += 1
                case .line(let point):
                    lines.append((current, point)); current = point
                case .quad(let control, let point):
                    let p0 = current
                    TextPathShape.flatten(p0.distance(to: control) + control.distance(to: point), into: &lines) { t in
                        let u = 1 - t
                        return CGPoint(x: u * u * p0.x + 2 * u * t * control.x + t * t * point.x, y: u * u * p0.y + 2 * u * t * control.y + t * t * point.y)
                    }
                    current = point
                case .cubic(let c1, let c2, let point):
                    let p0 = current
                    TextPathShape.flatten(p0.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: point), into: &lines) { t in
                        let u = 1 - t
                        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                        return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * point.x, y: a * p0.y + b * c1.y + c * c2.y + d * point.y)
                    }
                    current = point
                case .close:
                    lines.append((current, subpathStart)); current = subpathStart; lastClosed = true
                }
            }
            if reversed { lines = lines.reversed().map { ($0.1, $0.0) } }
            for (from, to) in lines {
                let distance = Double(from.distance(to: to))
                guard distance > 0, distance.isFinite else { continue }
                pieces.append(Piece(from: from, to: to, start: length, length: distance))
                length += distance
            }
            guard length > 0, length.isFinite else { return nil }
            closed = subpaths == 1 && lastClosed
            var first = CGPoint.zero
            for case .move(let point) in segments { first = point; break }
            end = reversed ? first : current
        }

        private static func flatten(_ controlLength: CGFloat, into lines: inout [(CGPoint, CGPoint)], _ point: (CGFloat) -> CGPoint) {
            let count = pieces(controlLength)
            var previous = point(0)
            for i in 1...count {
                let next = point(CGFloat(i) / CGFloat(count))
                lines.append((previous, next))
                previous = next
            }
        }

        /// The point and tangent angle (radians, SVG user space) for a character whose advance midpoint is `mid` along
        /// the path, or nil when the character falls off the path. `anchor` is the chunk's text-anchor (left-to-right).
        func place(_ mid: Double, anchor: String) -> (point: CGPoint, angle: CGFloat)? {
            var distance = mid
            if closed {
                let (low, high) = anchor == "middle" ? (-length / 2, length / 2) : anchor == "end" ? (-length, 0) : (0, length)
                guard mid - offset >= low, mid - offset <= high else { return nil }
                distance = mid.truncatingRemainder(dividingBy: length)
                if distance < 0 { distance += length }
            } else {
                guard mid >= 0, mid <= length else { return nil }
            }
            var low = 0, high = pieces.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if pieces[middle].start <= distance { low = middle } else { high = middle - 1 }
            }
            let piece = pieces[low]
            let t = CGFloat(min(max((distance - piece.start) / piece.length, 0), 1))
            let point = CGPoint(x: piece.from.x + (piece.to.x - piece.from.x) * t, y: piece.from.y + (piece.to.y - piece.from.y) * t)
            return (point, atan2(piece.to.y - piece.from.y, piece.to.x - piece.from.x))
        }
    }

    /// The path a ‘textPath’ refers to: its SVG 2 ‘path’ attribute when valid, otherwise the ‘path’ or basic shape its
    /// href names (with that element's own transform), with ‘side’ and ‘startOffset’ applied.
    static func textPathReference(_ textPath: XElement, targets: TextPathTargets, fontSize: Double) -> TextPathReference {
        var segments = textPath.attributeValue("path").flatMap(pathSegments) ?? []
        var pieces = TextPathShape.pieces(segments)
        var target: XElement?
        if !segments.contains(where: \.draws) {
            let href = (textPath.attributeValue(xlinkHref) ?? textPath.attributeValue("href") ?? "").trimmingCharacters(in: .whitespaces)
            guard href.hasPrefix("#"), let element = targets.ids[String(href.dropFirst())] else { return .invalid }
            let key = TextPathTargets.Key(element: ObjectIdentifier(element), fontSize: fontSize)
            let entry: (segments: [PathSegment], pieces: Int)?
            if let cached = targets.parsed[key] {
                entry = cached
            } else {
                entry = equivalentPath(element, fontSize: fontSize).map { path in
                    let matrix = transform(element.attributeValue("transform"))
                    let transformed = path.map { $0.applying(matrix) }
                    return (transformed, TextPathShape.pieces(transformed))
                }
                targets.parsed.updateValue(entry, forKey: key)
            }
            guard let entry else { return .unsupported }
            segments = entry.segments
            pieces = entry.pieces
            target = element
        }
        guard pieces <= targets.remainingPieces else { return .unsupported }
        targets.remainingPieces -= pieces
        let side = textPath.attributeValue("side")?.trimmingCharacters(in: .whitespaces).lowercased()
        guard let shape = TextPathShape(segments, reversed: side == "right") else { return .invalid }
        let offset = textPath.attributeValue("startOffset")?.trimmingCharacters(in: .whitespaces) ?? ""
        if offset.hasSuffix("%") {
            shape.offset = (Double(offset.dropLast()) ?? 0) * shape.length / 100
        } else {
            shape.offset = length(offset, fontSize: fontSize, percentOf: 0) ?? 0
            // ‘pathLength’ on the referenced path rescales author distances along it.
            if let pathLength = target?.attributeValue("pathLength").flatMap(Double.init), pathLength > 0, pathLength.isFinite {
                shape.offset *= shape.length / pathLength
            }
        }
        if !shape.offset.isFinite { shape.offset = 0 }
        return .shape(shape)
    }

    private static let xlinkHref = XName("href", namespace: "http://www.w3.org/1999/xlink")

    // ───────────────────────── Path data ─────────────────────────

    /// Absolute path segments; arcs become cubic Béziers.
    enum PathSegment {
        case move(CGPoint), line(CGPoint), quad(CGPoint, CGPoint), cubic(CGPoint, CGPoint, CGPoint), close

        var draws: Bool { if case .move = self { false } else { true } }

        func applying(_ t: CGAffineTransform) -> PathSegment {
            switch self {
            case .move(let p): .move(p.applying(t))
            case .line(let p): .line(p.applying(t))
            case .quad(let c, let p): .quad(c.applying(t), p.applying(t))
            case .cubic(let c1, let c2, let p): .cubic(c1.applying(t), c2.applying(t), p.applying(t))
            case .close: .close
            }
        }
    }

    /// The segments of SVG path data up to its first error, like a renderer draws it; nil when nothing parses.
    static func pathSegments(_ data: String) -> [PathSegment]? {
        var scanner = NumberScanner(data)
        var segments: [PathSegment] = []
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?, lastQuad: CGPoint?
        var command: UInt8 = 0
        while true {
            scanner.skipSeparators()
            guard let byte = scanner.peek else { break }
            if (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A {
                command = byte
                scanner.advance()
            } else if command == 0 || (command | 0x20) == 0x7A {
                break // numbers without a command, or after closepath
            }
            if segments.isEmpty && (command | 0x20) != 0x6D { return nil } // path data starts with a moveto
            let relative = command >= 0x61
            func point(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + CGFloat(x), y: current.y + CGFloat(y)) : CGPoint(x: x, y: y)
            }
            let previousControl = lastControl, previousQuad = lastQuad
            lastControl = nil; lastQuad = nil
            switch command | 0x20 {
            case 0x6D: // m
                guard let x = scanner.number(), let y = scanner.number() else { return segments.isEmpty ? nil : segments }
                current = point(x, y); start = current
                segments.append(.move(current))
                command = relative ? 0x6C : 0x4C // following pairs are lines
            case 0x6C: // l
                guard let x = scanner.number(), let y = scanner.number() else { return segments.isEmpty ? nil : segments }
                current = point(x, y); segments.append(.line(current))
            case 0x68: // h
                guard let x = scanner.number() else { return segments.isEmpty ? nil : segments }
                current = CGPoint(x: relative ? current.x + CGFloat(x) : CGFloat(x), y: current.y); segments.append(.line(current))
            case 0x76: // v
                guard let y = scanner.number() else { return segments.isEmpty ? nil : segments }
                current = CGPoint(x: current.x, y: relative ? current.y + CGFloat(y) : CGFloat(y)); segments.append(.line(current))
            case 0x63, 0x73: // c, s
                var c1 = previousControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                if (command | 0x20) == 0x63 {
                    guard let x1 = scanner.number(), let y1 = scanner.number() else { return segments.isEmpty ? nil : segments }
                    c1 = point(x1, y1)
                }
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return segments.isEmpty ? nil : segments }
                let c2 = point(x2, y2)
                current = point(x, y); segments.append(.cubic(c1, c2, current)); lastControl = c2
            case 0x71, 0x74: // q, t
                var control = previousQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                if (command | 0x20) == 0x71 {
                    guard let x1 = scanner.number(), let y1 = scanner.number() else { return segments.isEmpty ? nil : segments }
                    control = point(x1, y1)
                }
                guard let x = scanner.number(), let y = scanner.number() else { return segments.isEmpty ? nil : segments }
                current = point(x, y); segments.append(.quad(control, current)); lastQuad = control
            case 0x61: // a
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let x = scanner.number(), let y = scanner.number() else { return segments.isEmpty ? nil : segments }
                let to = point(x, y)
                segments += arc(from: current, to: to, rx: abs(rx), ry: abs(ry), rotation: rotation, large: large, sweep: sweep)
                current = to
            case 0x7A: // z
                segments.append(.close); current = start
            default:
                return segments.isEmpty ? nil : segments
            }
        }
        return segments.isEmpty ? nil : segments
    }

    /// An elliptical arc as cubic Béziers (SVG 2 implementation notes: endpoint to center parameterization).
    private static func arc(from p0: CGPoint, to p1: CGPoint, rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool) -> [PathSegment] {
        guard p0 != p1 else { return [] }
        guard rx > 0, ry > 0 else { return [.line(p1)] }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = Double(p0.x - p1.x) / 2, dy = Double(p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        var rx = rx, ry = ry
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(numerator, 0) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + Double(p0.x + p1.x) / 2, cy = sinPhi * cx1 + cosPhi * cy1 + Double(p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        // Radii or coordinates too large to compute with: the straight line, as for a zero radius.
        guard theta.isFinite, delta.isFinite, cx.isFinite, cy.isFinite else { return [.line(p1)] }
        let count = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(count), k = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: cx + cosPhi * rx * x - sinPhi * ry * y, y: cy + sinPhi * rx * x + cosPhi * ry * y)
        }
        var result: [PathSegment] = []
        for i in 0..<count {
            let a = theta + step * Double(i), b = a + step
            let end = i == count - 1 ? p1 : map(cos(b), sin(b))
            result.append(.cubic(map(cos(a) - k * sin(a), sin(a) + k * cos(a)), map(cos(b) + k * sin(b), sin(b) - k * cos(b)), end))
        }
        return result
    }

    /// The SVG 2 equivalent path of a ‘path’ or basic shape; nil for geometry in percentages; empty for anything else.
    private static func equivalentPath(_ element: XElement, fontSize: Double) -> [PathSegment]? {
        func value(_ name: String) -> Double?? {
            guard let text = element.attributeValue(XName(name)) else { return .some(nil) }
            if text.contains("%") { return nil }
            return .some(length(text, fontSize: fontSize, percentOf: 0))
        }
        func number(_ name: String) -> Double? { value(name) ?? nil }
        if ["rect", "circle", "ellipse", "line"].contains(element.name.localName) &&
            ["x", "y", "width", "height", "rx", "ry", "cx", "cy", "r", "x1", "y1", "x2", "y2"].contains(where: { value($0) == nil }) { return nil }
        switch element.name.localName {
        case "path":
            return pathSegments(element.attributeValue("d") ?? "") ?? []
        case "rect":
            let x = number("x") ?? 0, y = number("y") ?? 0, width = number("width") ?? 0, height = number("height") ?? 0
            guard width > 0, height > 0 else { return [] }
            var rx = number("rx").flatMap { $0 >= 0 ? $0 : nil }, ry = number("ry").flatMap { $0 >= 0 ? $0 : nil }
            rx = rx ?? ry; ry = ry ?? rx
            let cornerX = min(rx ?? 0, width / 2), cornerY = min(ry ?? 0, height / 2)
            let round = cornerX > 0 && cornerY > 0
            func p(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: px, y: py) }
            func corner(_ to: CGPoint, from: CGPoint) -> [PathSegment] { round ? arc(from: from, to: to, rx: cornerX, ry: cornerY, rotation: 0, large: false, sweep: true) : [] }
            let rx0 = round ? cornerX : 0, ry0 = round ? cornerY : 0
            var path: [PathSegment] = [.move(p(x + rx0, y)), .line(p(x + width - rx0, y))]
            path += corner(p(x + width, y + ry0), from: p(x + width - rx0, y))
            path.append(.line(p(x + width, y + height - ry0)))
            path += corner(p(x + width - rx0, y + height), from: p(x + width, y + height - ry0))
            path.append(.line(p(x + rx0, y + height)))
            path += corner(p(x, y + height - ry0), from: p(x + rx0, y + height))
            path.append(.line(p(x, y + ry0)))
            path += corner(p(x + rx0, y), from: p(x, y + ry0))
            return path + [.close]
        case "circle", "ellipse":
            let cx = number("cx") ?? 0, cy = number("cy") ?? 0
            let circle = element.name.localName == "circle"
            var rx = circle ? number("r") : number("rx"), ry = circle ? number("r") : number("ry")
            rx = rx ?? ry; ry = ry ?? rx
            guard let rx, let ry, rx > 0, ry > 0 else { return [] }
            let points = [CGPoint(x: cx + rx, y: cy), CGPoint(x: cx, y: cy + ry), CGPoint(x: cx - rx, y: cy), CGPoint(x: cx, y: cy - ry), CGPoint(x: cx + rx, y: cy)]
            var path: [PathSegment] = [.move(points[0])]
            for i in 1..<points.count { path += arc(from: points[i - 1], to: points[i], rx: rx, ry: ry, rotation: 0, large: false, sweep: true) }
            return path + [.close]
        case "line":
            return [.move(CGPoint(x: number("x1") ?? 0, y: number("y1") ?? 0)), .line(CGPoint(x: number("x2") ?? 0, y: number("y2") ?? 0))]
        case "polyline", "polygon":
            var scanner = NumberScanner(element.attributeValue("points") ?? "")
            var points: [CGPoint] = []
            while let x = scanner.number(), let y = scanner.number() { points.append(CGPoint(x: x, y: y)) }
            guard let first = points.first else { return [] }
            return [.move(first)] + points.dropFirst().map { .line($0) } + (element.name.localName == "polygon" ? [.close] : [])
        default:
            return []
        }
    }

    /// An SVG transform list; identity when it doesn't parse.
    static func transform(_ text: String?) -> CGAffineTransform {
        guard let text, !text.isEmpty else { return .identity }
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            guard !rest.isEmpty else { return result }
            guard let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") else { return .identity }
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            var scanner = NumberScanner(String(rest[rest.index(after: open)..<close]))
            var values: [Double] = []
            while let value = scanner.number() { values.append(value) }
            scanner.skipSeparators()
            guard scanner.peek == nil else { return .identity }
            let item: CGAffineTransform
            switch (name, values.count) {
            case ("matrix", 6): item = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case ("translate", 1), ("translate", 2): item = CGAffineTransform(translationX: values[0], y: values.count > 1 ? values[1] : 0)
            case ("scale", 1), ("scale", 2): item = CGAffineTransform(scaleX: values[0], y: values.count > 1 ? values[1] : values[0])
            case ("rotate", 1): item = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
            case ("rotate", 3):
                item = CGAffineTransform(translationX: -values[1], y: -values[2])
                    .concatenating(CGAffineTransform(rotationAngle: values[0] * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: values[1], y: values[2]))
            case ("skewX", 1): item = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): item = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return .identity
            }
            // The list applies right to left: the last transform is nearest the content.
            result = item.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
    }

    /// Numbers in path data, point lists and transforms: separators are whitespace and commas, and a sign or a second
    /// decimal point starts a new number ("1.5.5", "1-2").
    private struct NumberScanner {
        private let bytes: [UInt8]
        private var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x2C].contains(bytes[index]) { index += 1 }
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = index
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            var digits = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1; digits += 1 }
            if index < bytes.count, bytes[index] == 0x2E {
                index += 1
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = start; return nil }
            if index < bytes.count, bytes[index] | 0x20 == 0x65 {
                var exponent = index + 1
                if exponent < bytes.count, bytes[exponent] == 0x2B || bytes[exponent] == 0x2D { exponent += 1 }
                if exponent < bytes.count, (0x30...0x39).contains(bytes[exponent]) {
                    index = exponent
                    while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else { index = start; return nil }
            return value
        }

        /// An arc flag: a single 0 or 1, which may be written without a separator before the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
            defer { index += 1 }
            return bytes[index] == 0x31
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
}
