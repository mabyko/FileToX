// `IsValid` (ACadSharp 3.8.0): objects the writers leave out, and the small enums and helpers the writers use.

import Foundation

extension ACad {
    /// `ClipType`.
    enum ClipType { static let rectangular: Int16 = 1, polygonal: Int16 = 2 }

    /// `HookLineDirection`.
    enum HookLineDirection { static let opposite: Int16 = 0, same: Int16 = 1 }

    /// `HasValidDxfName`: lengths in UTF-16 units, no `InvalidCharacters`, and the first '*' only as the first
    /// character.
    static func hasValidDxfName(_ name: String, version: Version = .ac1032) -> Bool {
        guard !name.isEmpty else { return false }
        let length = name.utf16.count
        if version <= .ac1015 && length > 31 { return false }
        if length > 255 { return false }
        if let star = name.unicodeScalars.firstIndex(of: "*"), star != name.unicodeScalars.startIndex { return false }
        return !name.unicodeScalars.contains { "\\/:?\"<>|;,=`".unicodeScalars.contains($0) }
    }
}

extension ACad.TableEntry {
    /// The `TableEntry.Name` setter: a null or white-space name throws.
    func setName(_ value: String) throws {
        if value.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
            throw ACad.DxfException("Table entry [ACadSharp.Tables.\(type(of: self))] must have a name (Parameter 'value')")
        }
        name = value
    }
}

extension ACad.XYZ {
    /// CSMath `IsZero()` of a vector: its length within the epsilon.
    var isNearZero: Bool { ACad.MathHelper.isZero(length) }
}

extension ACad.CadObject {
    /// `IsValid(format, version)` with the overrides of the 3.8.0 model.
    func isValid(format: ACad.CadFileFormat, version: ACad.Version) throws -> Bool {
        var result = true
        if let orientable = self as? ACad.Orientable, orientable.normal.isNearZero { result = false }
        switch self {
        case let entry as ACad.TableEntry:
            if format == .dxf, !ACad.hasValidDxfName(entry.name, version: version) { result = false }
        case let ellipse as ACad.Ellipse:
            if !ACad.MathHelper.isZero(ACad.XYZ.dot(ellipse.normal, ellipse.majorAxisEndPoint)) { result = false }
        case let image as ACad.CadWipeoutBase:
            if image.clipBoundaryVertices.count < 2 { result = false }
            if let raster = image as? ACad.RasterImage {
                if raster.definitionReactor == nil { result = false }
                if raster.definition == nil { result = false }
            }
        case let insert as ACad.Insert:
            if insert.block == nil { result = false }
        default:
            break
        }
        return result
    }
}

extension ACad.Leader {
    /// `HasHookline`: the last segment along the horizontal direction (the angle throws for a zero vector).
    func hasHookline() throws -> Bool {
        guard vertices.count > 1 else { return false }
        let v = vertices[vertices.count - 2] - vertices[vertices.count - 1]
        let u = horizontalDirection
        guard !v.isNearZero, !u.isNearZero else {
            throw ACad.DxfWriteError("Cannot calculate the angle between two vectors, if one is zero.")
        }
        return ACad.MathHelper.isZero(acos(ACad.XYZ.dot(v, u) / (v.length * u.length)))
    }
}
