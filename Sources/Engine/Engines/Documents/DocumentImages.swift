// Document-local port of EbookFiles.CommonImage and EbookConverter's DataUri/MarkdownImages
// (Filee, MIT; see docs/upstream/Filee.LICENSE). ImageIO replaces ImageMagick decoding.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DocumentImages {
    static func commonImage(_ path: String, _ folder: String) throws -> (file: String, mediaType: String)? {
        let ext = FilePath.extension(path).lowercased()
        let types = [".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".jpe": "image/jpeg", ".jfif": "image/jpeg",
                     ".png": "image/png", ".gif": "image/gif", ".svg": "image/svg+xml"]
        if let type = types[ext] { return (path, type) }
        // Filee drops only unreadable pictures; filesystem/encoder errors must still fail the job.
        guard let image = try? ImageSupport.cgImage(path) else { return nil }
        let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let jpeg = !alpha && [".webp", ".avif", ".jxl", ".tif", ".tiff"].contains(ext)
        try FileManager.default.createDirectoryIfNeeded(folder)
        let file = FilePath.combine(folder, DocumentXML.guid() + (jpeg ? ".jpg" : ".png"))
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL,
                (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
            throw ConversionError("Could not create a picture encoder.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("Could not encode \(FilePath.fileName(path)).") }
        return (file, jpeg ? "image/jpeg" : "image/png")
    }

    static func sources(_ document: HDocument, _ output: String, _ work: String, markdown: Bool) throws -> [String: String] {
        let folderName = FilePath.fileNameWithoutExtension(output) + "_files"
        let folder = FilePath.combine(FilePath.directoryName(output)!, folderName)
        let converted = FilePath.combine(work, "document-images-" + DocumentXML.guid())
        var names: [String: String] = [:], result: [String: String] = [:]
        var visited = Set<String>()
        let images = document.sections.flatMap { HDocumentWalker.inlines(HDocumentWalker.flowBlocks($0)) }
            .compactMap { $0 as? HImage }
        for image in images {
            let key = image.path.lowercased()
            if let known = names[key] { result[image.path] = known; continue }
            guard visited.insert(key).inserted, let common = try commonImage(image.path, converted) else { continue }
            let target: String
            if markdown {
                try FileManager.default.createDirectoryIfNeeded(folder)
                let name = String(format: "img%04d", names.count + 1) + FilePath.extension(common.file).lowercased()
                try FileManager.default.copyItem(atPath: common.file, toPath: FilePath.combine(folder, name))
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                target = folderName.addingPercentEncoding(withAllowedCharacters: allowed)! + "/" + name
            } else {
                target = "data:\(common.mediaType);base64," + (try Data(contentsOf: URL(fileURLWithPath: common.file))).base64EncodedString()
            }
            names[key] = target
            result[image.path] = target
        }
        return result
    }
}
