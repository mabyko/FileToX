// Port of Filee.Engines/Ebooks/Book.cs.
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class BookMetadata {
    var title: String?
    var authors: [String] = []
    var language: String?
    var description: String?
    var publisher: String?
    var coverImage: String?
}

struct Book {
    let document: HDocument
    let metadata: BookMetadata
    init(_ document: HDocument, _ metadata: BookMetadata) { self.document = document; self.metadata = metadata }

    func displayTitle(_ sourcePath: String) -> String {
        if let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let heading = document.sections.flatMap(\.blocks).compactMap({ $0 as? HParagraph }).first(where: { $0.headingLevel > 0 }) {
            let text = HDocumentWalker.text(heading.inlines)
            if !text.isEmpty { return String(decoding: text.utf16.prefix(200), as: UTF16.self) }
        }
        return FormatRegistry.nameWithoutExtension(sourcePath)
    }

    func displayLanguage() -> String {
        if let language = metadata.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty { return language }
        var hangul = 0, han = 0, kana = 0, latin = 0
        for text in document.sections.flatMap({ HDocumentWalker.inlines($0.blocks) }).compactMap({ $0 as? HText }).prefix(2000) {
            for ch in text.text.utf16 {
                switch ch {
                case 0xAC00...0xD7A3: hangul += 1
                case 0x3040...0x30FF: kana += 1
                case 0x4E00...0x9FFF: han += 1
                case 65...90, 97...122: latin += 1
                default: break
                }
            }
        }
        return hangul > 0 && hangul * 3 >= latin ? "ko" : kana > 0 && kana * 3 >= latin ? "ja" : han > 0 && han * 3 >= latin ? "zh" : "en"
    }
}

enum EbookFiles {
    static let drmMessage = "This book is protected with DRM (copy protection), so it cannot be converted. Filee does not remove DRM; open it in the reading app it was bought for."

    static func extract(_ zip: ZipReader, _ folder: String) throws {
        try FileManager.default.createDirectoryIfNeeded(folder)
        for entry in zip.entries {
            if entry.name.hasSuffix("/") || entry.name.hasSuffix("\\") { continue }
            guard let target = safePath(folder, entry.name) else { continue }
            try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(target)!)
            try zip.extract(entry, to: target)
        }
    }

    static func safePath(_ root: String, _ entryName: String) -> String? {
        let relative = String(entryName.replacingOccurrences(of: "\\", with: "/").drop(while: { $0 == "/" }))
        guard !relative.isEmpty, !relative.contains(":"), !relative.utf8.contains(0) else { return nil }
        let full = FilePath.fullPath(FilePath.combine(root, relative))
        let prefix = FilePath.fullPath(root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolutePrefix = "/" + prefix + "/"
        return full.lowercased().hasPrefix(absolutePrefix.lowercased()) ? full : nil
    }

    static func newFolder(_ workDirectory: String, _ prefix: String) throws -> String {
        let folder = FilePath.combine(workDirectory, "\(prefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))")
        try FileManager.default.createDirectoryIfNeeded(folder)
        return folder
    }

    static func commonImage(_ path: String, _ folder: String, _ gifAndSvg: Bool) -> (file: String, mediaType: String)? {
        let mediaType = imageMediaType(path)
        if ["image/jpeg", "image/png"].contains(mediaType ?? "") || gifAndSvg && ["image/gif", "image/svg+xml"].contains(mediaType ?? "") {
            return (path, mediaType!)
        }
        do {
            let image = try ImageSupport.cgImage(path)
            let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let jpeg = !alpha && ["image/webp", "image/avif", "image/jxl", "image/tiff"].contains(mediaType ?? "")
            try FileManager.default.createDirectoryIfNeeded(folder)
            let file = FilePath.combine(folder, "\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()).\(jpeg ? "jpg" : "png")")
            guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, (jpeg ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil) else { return nil }
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            if let info = ImageSupport.info(path) {
                if let x = info.dpiX { properties[kCGImagePropertyDPIWidth] = x }
                if let y = info.dpiY { properties[kCGImagePropertyDPIHeight] = y }
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return (file, jpeg ? "image/jpeg" : "image/png")
        } catch { return nil }
    }

    static func imageMediaType(_ path: String) -> String? {
        switch FilePath.extension(path).lowercased() {
        case ".jpg", ".jpeg", ".jpe", ".jfif": return "image/jpeg"
        case ".png": return "image/png"
        case ".gif": return "image/gif"
        case ".svg": return "image/svg+xml"
        case ".webp": return "image/webp"
        case ".bmp": return "image/bmp"
        case ".tif", ".tiff": return "image/tiff"
        case ".avif": return "image/avif"
        case ".jxl": return "image/jxl"
        default: return nil
        }
    }

    // .NET's overwrite move; keep output untouched until the writer closes successfully.
    static func replace(_ source: String, _ target: String) throws {
        if rename(source, target) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func files(_ folder: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder) else { return [] }
        return enumerator.compactMap { $0 as? String }.map { FilePath.combine(folder, $0) }.filter { FileManager.default.fileExists($0) }
    }

    static func uriEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? value
    }
}
