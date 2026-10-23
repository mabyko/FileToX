// Port of Filee.Engines/Ebooks/ComicBook.cs; SharpCompress → ZIP / bundled 7-Zip, PDFsharp/PDFium → CoreGraphics/PDFKit.
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ComicBook {
    private static let pictureExtensions: Set<String> = [".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".gif", ".webp", ".bmp", ".avif", ".jxl", ".tif", ".tiff", ".heic", ".heif"]
    static func extractPages(_ path: String, _ format: String, _ folder: String) async throws -> [String] {
        if format == "cbc" {
            let comics = try await extractArchive(path, EbookFiles.newFolder(folder, "cbc")) { FilePath.extension($0).lowercased() == ".cbz" || FilePath.fileName($0).lowercased() == "comics.txt" }
            // Filee renames extracted entries, so CBC reading lists keep its existing failure behavior.
            let list = comics.first { FilePath.fileName($0).lowercased() == "comics.txt" }
            var books = comics.filter { $0 != list }
            if let list {
                let order = TextEncodings.decodeText(try Data(contentsOf: URL(fileURLWithPath: list))).components(separatedBy: .newlines).map { $0.components(separatedBy: ":")[0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                func ordinal(_ book: String) -> Int { order.firstIndex { book.lowercased().hasSuffix($0.lowercased()) } ?? Int.max }
                books.sort { ordinal($0) < ordinal($1) }
            }
            var pages: [String] = []
            for book in books { pages += try await extractPages(book, "cbz", EbookFiles.newFolder(folder, "cbz")) }
            return pages
        }
        let pages = try await extractArchive(path, folder) { pictureExtensions.contains(FilePath.extension($0).lowercased()) }
        if pages.isEmpty { throw ConversionError("The comic contains no pictures.") }
        return pages
    }

    private static let damagedArchive = "The comic archive cannot be opened (damaged, or not the format its extension says)."
    private static func extractArchive(_ path: String, _ folder: String, _ wanted: (String) -> Bool) async throws -> [String] {
        try FileManager.default.createDirectoryIfNeeded(folder)
        var files: [(key: String, file: String)] = []
        func target(_ key: String, _ directory: Bool, _ encrypted: Bool) throws -> String? {
            try Task.checkCancellation()
            let name = FilePath.fileName(key.replacingOccurrences(of: "\\", with: "/"))
            if directory || key.lowercased().contains("__macosx") || name.hasPrefix(".") || !wanted(name) { return nil }
            if encrypted { throw ConversionError("The comic archive is password-protected.") }
            let file = FilePath.combine(folder, String(format: "%05d%@", files.count, FilePath.extension(name).lowercased()))
            files.append((key, file)); return file
        }
        // ZIP detection is content-based, as ArchiveFactory was (a CBZ may have another extension).
        if let zip = try? ZipReader(path: path) {
            if zip.entries.contains(where: \.isEncrypted) { throw ConversionError("The comic archive is password-protected.") }
            for entry in zip.entries {
                guard let file = try target(entry.name, entry.isDirectory, entry.isEncrypted) else { continue }
                try zip.extract(entry, to: file)
            }
        } else {
            guard let executable = EngineEnvironment.bundledProgram("7zip", "7zz") else { throw ConversionError("7-Zip was not found (engines/7zip).") }
            let listing = try await ProcessRunner.run(executable, ["l", "-slt", "-sccUTF-8", "-bsp0", "-pfilee-no-password", "--", FilePath.fullPath(path)], timeout: 21600)
            if listing.exitCode != 0 && listing.exitCode != 1 {
                if (listing.standardError + listing.standardOutput).lowercased().contains("password") { throw ConversionError("The comic archive is password-protected.") }
                throw ConversionError(damagedArchive)
            }
            let entries = parseListing(listing.standardOutput)
            if entries.contains(where: { $0["Encrypted"] == "+" }) { throw ConversionError("The comic archive is password-protected.") }
            let extracted = try EbookFiles.newFolder(folder, "archive")
            var selected: [(String, String)] = []
            for entry in entries {
                guard let key = entry["Path"] else { continue }
                let directory = entry["Folder"] == "+" || (entry["Attributes"] ?? "").hasPrefix("D")
                guard let file = try target(key, directory, false) else { continue }
                // Only regular entries under this private folder are ever passed to 7-Zip.
                guard EbookFiles.safePath(extracted, key) != nil, (entry["Symbolic Link"] ?? "").isEmpty, (entry["Hard Link"] ?? "").isEmpty, !(entry["Mode"] ?? "").hasPrefix("l"), !key.contains("\n"), !key.contains("\r") else { throw ConversionError(damagedArchive) }
                selected.append((key, file))
            }
            if !selected.isEmpty {
                let list = FilePath.combine(folder, "comic-items.txt")
                try Data((selected.map(\.0).joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: list))
                let result = try await ProcessRunner.run(executable, ["x", "-y", "-aou", "-sccUTF-8", "-scsUTF-8", "-bsp0", "-bb0", "-pfilee-no-password", "-o" + FilePath.fullPath(extracted), "-spd", "-i@" + list, "--", FilePath.fullPath(path)], timeout: 21600)
                if result.exitCode != 0 && result.exitCode != 1 { throw ConversionError(damagedArchive) }
                for (key, file) in selected {
                    guard let source = EbookFiles.safePath(extracted, key), FileManager.default.fileExists(source) else { throw ConversionError(damagedArchive) }
                    try FileManager.default.copyItem(atPath: source, toPath: file)
                }
            }
        }
        return files.sorted { NaturalComparer.compare($0.key, $1.key) < 0 }.map(\.file)
    }
    private static func parseListing(_ output: String) -> [[String: String]] {
        var result: [[String: String]] = [], fields: [String: String] = [:], inEntries = false
        func flush() { if fields["Path"] != nil { result.append(fields) }; fields = [:] }
        for raw in output.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if !inEntries { inEntries = line.hasPrefix("----------"); continue }
            if line.isEmpty { flush(); continue }
            if let range = line.range(of: " = ") { fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...]) }
            else if line.hasSuffix(" =") { fields[String(line.dropLast(2))] = "" }
        }
        flush(); return result
    }

    static func toPdf(_ pages: [String], _ output: String, _ workFolder: String, _ progress: ProgressHandler?) throws {
        let converted = try EbookFiles.newFolder(workFolder, "pdf-pages")
        guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: output) as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConversionError("Could not create the PDF.") }
        defer { context.closePDF() }
        var count = 0
        for i in pages.indices {
            try Task.checkCancellation()
            guard let (file, _) = EbookFiles.commonImage(pages[i], converted, false) else { continue }
            guard let info = EbookFiles.imageInfo(file) else { throw ConversionError("The comic contains no readable pictures.") }
            // MagickImageInfo reports 72 dpi for untagged JPEGs; untagged PNGs fall back to 96.
            let density = info.dpiX ?? (EbookFiles.imageMediaType(file) == "image/jpeg" ? 72 : 0)
            let dpi = density >= 36 ? density : 96
            var rect = CGRect(x: 0, y: 0, width: Double(info.width) / dpi * 72, height: Double(info.height) / dpi * 72)
            // Data providers preserve JPEG's encoded bytes in a PDF, as PDFsharp did.
            let image: CGImage
            if EbookFiles.imageMediaType(file) == "image/jpeg", let provider = CGDataProvider(url: URL(fileURLWithPath: file) as CFURL), let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) { image = jpeg }
            else { image = try EbookFiles.cgImage(file) }
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.draw(image, in: rect); context.endPDFPage(); count += 1
            progress?(Double(i + 1) / Double(pages.count))
        }
        if count == 0 { throw ConversionError("The comic contains no readable pictures.") }
    }
    static func toCbz(_ pages: [String], _ output: String) throws {
        let temp = output + ".tmp", zip = try ZipWriter(path: temp), digits = max(3, String(pages.count).count)
        for i in pages.indices {
            try Task.checkCancellation()
            let name = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + "\(i + 1)" + FilePath.extension(pages[i]).lowercased()
            try zip.add(name, contentsOf: pages[i], level: .noCompression)
        }
        try zip.close(); try EbookFiles.replace(temp, output)
    }
    static func renderPdf(_ pdf: String, _ step: ConversionStep, _ folder: String, _ progress: ProgressHandler?) throws -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: pdf)) else { throw ConversionError("The PDF could not be opened.") }
        let pageNumbers = PageRange.parse(step.preset.pdf.pageRange, pageCount: document.pageCount)
        let dpi = min(600, max(36, step.preset.pdf.renderDpi)), quality = min(100, max(1, step.preset.image.quality))
        var pages: [String] = []
        for number in pageNumbers {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            let bounds = page.bounds(for: .mediaBox), scale = Double(dpi) / 72
            let rotated = page.rotation % 180 != 0
            let width = max(1, Int(((rotated ? bounds.height : bounds.width) * scale).rounded(.up)))
            let height = max(1, Int(((rotated ? bounds.width : bounds.height) * scale).rounded(.up)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConversionError("Could not render the PDF page.") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { throw ConversionError("Could not render the PDF page.") }
            let file = FilePath.combine(folder, String(format: "%05d.jpg", pages.count + 1))
            guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ConversionError("Could not encode the PDF page.") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary)
            if !CGImageDestinationFinalize(destination) { throw ConversionError("Could not encode the PDF page.") }
            pages.append(file); progress?(0.9 * Double(pages.count) / Double(max(1, pageNumbers.count)))
        }
        return pages
    }
}

enum NaturalComparer {
    private static func lower(_ unit: UInt16) -> UInt16 {
        if (0xD800...0xDFFF).contains(unit) { return unit }
        let text = String(UnicodeScalar(unit)!).lowercased()
        return text.utf16.count == 1 ? text.utf16.first! : unit
    }
    static func compare(_ x: String?, _ y: String?) -> Int {
        guard let left = x, let right = y else { return x == nil ? (y == nil ? 0 : -1) : 1 }
        let x = Array(left.utf16), y = Array(right.utf16)
        var i = 0, j = 0
        while i < x.count && j < y.count {
            if (48...57).contains(x[i]) && (48...57).contains(y[j]) {
                var startX = i, startY = j
                while i < x.count && (48...57).contains(x[i]) { i += 1 }
                while j < y.count && (48...57).contains(y[j]) { j += 1 }
                while startX < i && x[startX] == 48 { startX += 1 }
                while startY < j && y[startY] == 48 { startY += 1 }
                let numberX = Array(x[startX..<i]), numberY = Array(y[startY..<j])
                if numberX.count != numberY.count { return numberX.count < numberY.count ? -1 : 1 }
                if numberX != numberY { return numberX.lexicographicallyPrecedes(numberY) ? -1 : 1 }
                continue
            }
            let a = lower(x[i]), b = lower(y[j])
            if a != b { return a < b ? -1 : 1 }
            i += 1; j += 1
        }
        let a = x.count - i, b = y.count - j
        return a == b ? 0 : a < b ? -1 : 1
    }
}
