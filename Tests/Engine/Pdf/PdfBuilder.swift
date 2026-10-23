// Port of Filee.Engines.Tests/PdfBuilder.cs: small PDF files for the PDF reader tests, written as raw PDF syntax (Filee
// used PdfPig's writer): text in the standard 14 fonts (nothing embedded, every reader has them), wrapped paragraphs,
// colours, pictures, links and several pages. `y` coordinates are points from the top of the page. Text is measured with
// Core Text's Helvetica, the font PDF readers on macOS substitute.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
@testable import FileToXEngineKit

final class PdfBuilder {
    struct Font {
        let resource: String
        let ctFont: CTFont
    }

    private struct Page {
        var width: Double
        var height: Double
        var content = ""
        var fonts: [String: String] = [:] // resource → base font
        var images: [String: Int] = [:] // resource → object number
        var annotations: [Int] = []
    }

    private var objects: [Int: Data] = [:]
    private var nextObject = 3 // 1 catalog, 2 pages
    private var pages: [Page] = []
    private var fontNames: [String: String] = [:] // base font → resource

    private var page: Page {
        get { pages[pages.count - 1] }
        set { pages[pages.count - 1] = newValue }
    }

    /// Starts a new page (A4 by default).
    @discardableResult
    func newPage(_ width: Double = 595, _ height: Double = 842) -> PdfBuilder {
        pages.append(Page(width: width, height: height))
        return self
    }

    /// Helvetica in the given style (a standard font: nothing is embedded).
    func font(bold: Bool = false, italic: Bool = false) -> Font {
        let base = bold && italic ? "Helvetica-BoldOblique" : bold ? "Helvetica-Bold" : italic ? "Helvetica-Oblique" : "Helvetica"
        let resource = fontNames[base] ?? "F\(fontNames.count + 1)"
        fontNames[base] = resource
        page.fonts[resource] = base
        return Font(resource: resource, ctFont: CTFontCreateWithName(base as CFString, 1, nil))
    }

    func width(_ text: String, _ size: Double, _ font: Font) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): CTFontCreateCopyWithAttributes(font.ctFont, size, nil, nil)])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }

    /// One line of text with its baseline `y` points below the top of the page.
    @discardableResult
    func line(_ text: String, _ size: Double, _ font: Font, _ x: Double, _ y: Double, color: (UInt8, UInt8, UInt8)? = nil) -> PdfBuilder {
        page.fonts[font.resource] = fontNames.first { $0.value == font.resource }?.key
        let escaped = text.unicodeScalars.map { scalar -> String in
            switch scalar {
            case "(", ")", "\\": return "\\" + String(scalar)
            default:
                guard scalar.value < 128 else { return String(format: "\\%03o", winAnsi(scalar)) }
                return String(scalar)
            }
        }.joined()
        if let color { page.content += String(format: "%.4f %.4f %.4f rg ", Double(color.0) / 255, Double(color.1) / 255, Double(color.2) / 255) }
        page.content += String(format: "BT /%@ %.2f Tf %.3f %.3f Td (%@) Tj ET\n", font.resource, size, x, page.height - y, escaped)
        if color != nil { page.content += "0 g\n" }
        return self
    }

    private func winAnsi(_ scalar: Unicode.Scalar) -> UInt32 {
        String(scalar).data(using: .windowsCP1252)?.first.map(UInt32.init) ?? 63
    }

    /// Text wrapped at word boundaries into `width`; returns the baseline below the last line.
    @discardableResult
    func paragraph(_ text: String, _ size: Double, _ font: Font, _ x: Double, _ y: Double, _ width: Double, _ leading: Double) -> Double {
        var y = y
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty && self.width(candidate, size, font) > width {
                line(current, size, font, x, y)
                y += leading
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            line(current, size, font, x, y)
            y += leading
        }
        return y
    }

    /// A JPEG (kept as a DCT stream) or PNG (as RGB samples) picture drawn into the rectangle.
    @discardableResult
    func picture(_ path: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) throws -> PdfBuilder {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let number = nextObject
        nextObject += 1
        var stream: Data
        var header = "<< /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /ColorSpace /DeviceRGB /BitsPerComponent 8"
        if path.lowercased().hasSuffix(".png") {
            let bitmap = ImagePixels.bitmap(image)
            var rgb = Data(capacity: image.width * image.height * 3)
            for i in 0..<image.width * image.height { rgb.append(contentsOf: bitmap.pixels[i * 4..<i * 4 + 3]) }
            stream = try Deflate.deflate(rgb, windowBits: 15)
            header += " /Filter /FlateDecode"
        } else {
            stream = bytes
            header += " /Filter /DCTDecode"
        }
        objects[number] = Data((header + " /Length \(stream.count) >>\nstream\n").utf8) + stream + Data("\nendstream".utf8)
        let resource = "Im\(page.images.count + 1)"
        page.images[resource] = number
        page.content += String(format: "q %.3f 0 0 %.3f %.3f %.3f cm /%@ Do Q\n", width, height, x, page.height - y - height, resource)
        return self
    }

    /// A web link over the rectangle.
    @discardableResult
    func link(_ url: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PdfBuilder {
        let number = nextObject
        nextObject += 1
        let rect = String(format: "%.3f %.3f %.3f %.3f", x, page.height - y - height, x + width, page.height - y)
        objects[number] = Data("<< /Type /Annot /Subtype /Link /Rect [\(rect)] /Border [0 0 0] /A << /S /URI /URI (\(url)) >> >>".utf8)
        page.annotations.append(number)
        return self
    }

    /// A gradient picture (#FF8800 → #0044AA) of the given size in the format of the name's extension.
    static func photo(_ folder: String, _ name: String, _ width: Int = 200, _ height: Int = 120) throws -> String {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let t = height > 1 ? Double(y) / Double(height - 1) : 0
            let rgb = [0xFF + (0x00 - 0xFF) * t, 0x88 + (0x44 - 0x88) * t, 0x00 + (0xAA - 0x00) * t]
            for x in 0..<width { for c in 0..<3 { pixels[(y * width + x) * 4 + c] = UInt8(rgb[c].rounded()) }; pixels[(y * width + x) * 4 + 3] = 255 }
        }
        let image = ImagePixels.make(pixels, width, height, components: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: false)
        let path = FilePath.combine(folder, name)
        try ImageEncoder.save([ImageFrame(image: image)], to: path, format: FormatRegistry.detect(path)!.id)
        return path
    }

    @discardableResult
    func save(_ path: String) throws -> String {
        var fontObjects: [String: Int] = [:]
        for base in fontNames.keys.sorted() {
            fontObjects[base] = nextObject
            objects[nextObject] = Data("<< /Type /Font /Subtype /Type1 /BaseFont /\(base) /Encoding /WinAnsiEncoding >>".utf8)
            nextObject += 1
        }
        var kids: [Int] = []
        for page in pages {
            let content = nextObject
            objects[content] = Data("<< /Length \(page.content.utf8.count) >>\nstream\n\(page.content)\nendstream".utf8)
            let number = nextObject + 1
            nextObject += 2
            let fonts = page.fonts.sorted { $0.key < $1.key }.map { "/\($0.key) \(fontObjects[$0.value]!) 0 R" }.joined(separator: " ")
            let images = page.images.sorted { $0.key < $1.key }.map { "/\($0.key) \($0.value) 0 R" }.joined(separator: " ")
            let annotations = page.annotations.isEmpty ? "" : " /Annots [\(page.annotations.map { "\($0) 0 R" }.joined(separator: " "))]"
            objects[number] = Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(page.width) \(page.height)] /Resources << /Font << \(fonts) >>"
                + " /XObject << \(images) >> >> /Contents \(content) 0 R\(annotations) >>").utf8)
            kids.append(number)
        }
        objects[1] = Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)
        objects[2] = Data("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>".utf8)

        var file = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\n".utf8)
        var offsets: [Int: Int] = [:]
        let count = (objects.keys.max() ?? 0) + 1
        for number in 1..<count {
            guard let body = objects[number] else { continue }
            offsets[number] = file.count
            file += Data("\(number) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        let xref = file.count
        var table = "xref\n0 \(count)\n0000000000 65535 f \n"
        for number in 1..<count { table += String(format: "%010d 00000 %@ \n", offsets[number] ?? 0, offsets[number] == nil ? "f" : "n") }
        file += Data((table + "trailer\n<< /Size \(count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8)
        try file.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Encrypts a PDF with a password needed to open it.
    static func protect(_ path: String, _ password: String) throws {
        let document = PDFDocument(url: URL(fileURLWithPath: path))!
        guard document.write(to: URL(fileURLWithPath: path), withOptions: [.userPasswordOption: password, .ownerPasswordOption: password + "-owner"]) else {
            throw ConversionError("could not encrypt")
        }
    }
}
