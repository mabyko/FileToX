import CNativeSvg
import CoreGraphics
import Foundation

/// A deliberately small native capability set. Every other SVG keeps CoreSVG, including CSS, text,
/// references/resources, symbols, nested viewports, gradients, filters and transformed geometry.
enum NativeSvgRasterizer {
    static func supports(_ data: Data) -> Bool {
        let svgNamespace = "http://www.w3.org/2000/svg"
        guard data.count <= 8 * 1024 * 1024, let document = try? XDocument.load(data: data),
              document.root.name.localName == "svg", document.root.attributeValue("xmlns") == svgNamespace else { return false }
        let paint: Set<String> = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "fill-rule", "id"]
        let colors: Set<String> = ["none", "black", "white", "red", "green", "blue"]
        for element in document.root.descendantsAndSelf() {
            guard element.name.namespaceName == svgNamespace else { return false }
            // Skia ignores prefixed element names; keep a consistent default namespace through serialization.
            if let namespace = element.attributeValue("xmlns"), namespace != svgNamespace { return false }
            let allowed: Set<String>
            switch element.name.localName {
            case "svg" where element === document.root: allowed = paint.union(["width", "height", "viewBox", "version"])
            case "g": allowed = paint
            case "rect": allowed = paint.union(["x", "y", "width", "height", "rx", "ry"])
            case "path": allowed = paint.union(["d"])
            default: return false
            }
            for attribute in element.attributes where !attribute.isNamespaceDeclaration {
                let name = attribute.name.localName, value = attribute.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard attribute.name.namespaceName.isEmpty, allowed.contains(name) else { return false }
                switch name {
                case "fill", "stroke":
                    let hex = value.hasPrefix("#") ? String(value.dropFirst()) : ""
                    guard colors.contains(value) || ([3, 6].contains(hex.count) && hex.allSatisfy({ $0.isASCII && $0.isHexDigit })) else { return false }
                case "stroke-linecap": guard ["butt", "round", "square"].contains(value) else { return false }
                case "stroke-linejoin": guard ["miter", "round", "bevel"].contains(value) else { return false }
                case "fill-rule": guard ["nonzero", "evenodd"].contains(value) else { return false }
                case "d", "id": break
                case "viewBox":
                    let tokens = value.split(whereSeparator: { $0.isWhitespace || $0 == "," })
                    let values = tokens.compactMap { Float($0) }
                    guard tokens.count == 4, values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), values[2] > 0, values[3] > 0 else { return false }
                case "version": guard ["1.0", "1.1", "2.0"].contains(value) else { return false }
                default:
                    guard let number = Float(value), number.isFinite, abs(number) <= 1_000_000 else { return false }
                    if !["x", "y"].contains(name) && number < 0 { return false }
                    if name == "stroke-miterlimit" && number < 1 { return false }
                }
            }
        }
        return true
    }

    /// The CGContext owns storage; the C bridge borrows it only for the duration of this call.
    static func render(_ data: Data, bounds: CGRect, scale: Float, into context: CGContext) throws -> Bool {
        try Task.checkCancellation()
        guard let pixels = context.data else { return false }
        let status = data.withUnsafeBytes { bytes in
            ftx_svg_render(bytes.baseAddress, bytes.count, Float(bounds.width), Float(bounds.height), scale,
                           Int32(context.width), Int32(context.height), pixels, context.bytesPerRow * context.height,
                           { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
        }
        if status == 3 { throw CancellationError() }
        try Task.checkCancellation()
        return status == 0
    }
}
