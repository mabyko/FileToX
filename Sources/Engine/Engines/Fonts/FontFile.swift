// Port of Filee.Engines/Fonts/FontFile.cs.
import Foundation

enum FontFile {
    static let formats = ["ttf", "otf", "woff", "woff2", "eot"]
    static func load(_ data: Data) throws -> SfntFont {
        if data.count >= 4 {
            switch BinaryPrimitives.readUInt32BigEndian(data) {
            case Woff.signature: return try Woff.decode(data)
            case Woff2.signature: return try Woff2.decode(data)
            default: break
            }
        }
        if SfntFont.isSfnt(data) { return try SfntFont.read(data) }
        if Eot.isEot(data) { return try Eot.decode(data) }
        throw ConversionError("This file is not a font Filee can read (TTF, OTF, WOFF, WOFF2 or EOT).")
    }
    static func save(_ font: SfntFont, _ format: String, _ progress: ProgressHandler? = nil) throws -> Data {
        switch format {
        case "ttf": return try trueTypeOutlines(font, progress).write()
        case "otf": return font.write()
        case "woff": return try Woff.encode(font)
        case "woff2": return try Woff2.encode(font, progress)
        case "eot": return try Eot.encode(trueTypeOutlines(font, progress))
        default: throw ConversionError("Unknown font format '\(format)'. (Parameter 'format')")
        }
    }
    private static func trueTypeOutlines(_ font: SfntFont, _ progress: ProgressHandler?) throws -> SfntFont {
        font["glyf"] == nil && (font["CFF "] != nil || font["CFF2"] != nil) ? try CffToTrueType.convert(font, progress) : font
    }
}
