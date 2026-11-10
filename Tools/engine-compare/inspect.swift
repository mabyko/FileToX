import Foundation
import AppKit
import ImageIO
import CoreGraphics
import PDFKit
import CryptoKit
import Vision
import Darwin

enum InspectError: Error { case invalid(String) }

func source(_ path: String) throws -> CGImageSource {
    // ImageIO swaps red/blue when reading ImageMagick's 32-bit indexed TGA
    // palette. Expand that palette to a truecolour TGA before decoding it.
    if let input = try? Data(contentsOf: URL(fileURLWithPath: path)), input.count >= 18,
       input[1] == 1, input[2] == 1, input[7] == 32, input[16] == 8 {
        let count = Int(input[5]) | Int(input[6]) << 8
        let base = Int(input[3]) | Int(input[4]) << 8
        let width = Int(input[12]) | Int(input[13]) << 8
        let height = Int(input[14]) | Int(input[15]) << 8
        let palette = 18 + Int(input[0]), start = palette + count * 4
        if count > 0, width > 0, height > 0, width * height <= 100_000_000, start + width * height <= input.count {
            var data = Data(input.prefix(18))
            data[0] = 0; data[1] = 0; data[2] = 2; data[16] = 32
            for at in 3...7 { data[at] = 0 }
            for index in input[start..<start + width * height] {
                let item = Int(index) - base
                guard (0..<count).contains(item) else { throw InspectError.invalid("Invalid TGA palette index") }
                data.append(input[palette + item * 4..<palette + item * 4 + 4])
            }
            if let value = CGImageSourceCreateWithData(data as CFData, nil) { return value }
        }
    }
    guard let value = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        throw InspectError.invalid("ImageIO cannot read this image")
    }
    return value
}

func recognizedText(_ path: String) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "ko-KR"]
    let src = try source(path)
    guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw InspectError.invalid("Cannot decode image") }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

func pixels(_ source: CGImageSource, _ index: Int) throws -> (Int, Int, [UInt8]) {
    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
        throw InspectError.invalid("ImageIO cannot decode frame \(index)")
    }
    let w = image.width, h = image.height
    guard w > 0, h > 0, w * h <= 100_000_000 else {
        throw InspectError.invalid("Image exceeds 100 million pixel inspection limit")
    }
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { throw InspectError.invalid("Cannot create pixel context") }
    return (w, h, bytes)
}

func imageInfo(_ path: String) throws -> [String: Any] {
    let src = try source(path)
    let count = CGImageSourceGetCount(src)
    guard count > 0 else { throw InspectError.invalid("No image frames") }
    var frames = [[String: Any]]()
    for index in 0..<count {
        let p = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
        let (w, h, bytes) = try pixels(src, index)
        let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        frames.append(["width": w, "height": h, "hasAlpha": p[kCGImagePropertyHasAlpha as String] ?? false,
            "colorModel": p[kCGImagePropertyColorModel as String] ?? "unknown",
            "dpiX": p[kCGImagePropertyDPIWidth as String] ?? NSNull(),
            "dpiY": p[kCGImagePropertyDPIHeight as String] ?? NSNull(), "pixelSha256": digest])
    }
    return ["frameCount": count, "frames": frames]
}

func pixelScores(_ p: [UInt8], _ q: [UInt8]) -> [String: Any] {
    var square = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
    for i in 0..<p.count {
        let d = Double(p[i]) - Double(q[i]); square += d * d
    }
    for i in stride(from: 0, to: p.count, by: 4) {
        let x = 0.2126 * Double(p[i]) + 0.7152 * Double(p[i+1]) + 0.0722 * Double(p[i+2])
        let y = 0.2126 * Double(q[i]) + 0.7152 * Double(q[i+1]) + 0.0722 * Double(q[i+2])
        sx += x; sy += y; sxx += x*x; syy += y*y; sxy += x*y
    }
    let n = Double(p.count/4), mx = sx/n, my = sy/n
    let vx = max(0, sxx/n-mx*mx), vy = max(0, syy/n-my*my), cov = sxy/n-mx*my
    let ssim = ((2*mx*my+6.5025)*(2*cov+58.5225))/((mx*mx+my*my+6.5025)*(vx+vy+58.5225))
    let mse = square / Double(p.count)
    return ["psnr": mse == 0 ? 99.0 : 10*log10(65025/mse), "ssim": ssim]
}

func compareImages(_ left: String, _ right: String) throws -> [String: Any] {
    let a = try source(left), b = try source(right)
    let count = CGImageSourceGetCount(a)
    guard count > 0, count == CGImageSourceGetCount(b) else { return ["sameGeometry": false] }
    var scores = [[String: Any]]()
    for index in 0..<count {
        let (w, h, p) = try pixels(a, index), (bw, bh, q) = try pixels(b, index)
        guard w == bw, h == bh else { return ["sameGeometry": false] }
        scores.append(pixelScores(p, q))
    }
    return ["sameGeometry": true, "frames": scores]
}

func documentInfo(_ path: String) throws -> [String: Any] {
    let value = try NSAttributedString(url: URL(fileURLWithPath: path),
        options: [.documentType: NSAttributedString.DocumentType.docFormat], documentAttributes: nil)
    guard value.length <= 8 * 1024 * 1024 else { throw InspectError.invalid("DOC text limit") }
    var runs = [[String: Any]](), pictures = [[String: Any]](), unknown = Set<String>(), failure: Error?
    var imageBytes = 0
    func color(_ color: NSColor) -> [CGFloat] {
        guard let c = color.usingColorSpace(.sRGB) else { unknown.insert("unconvertible color"); return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }
    value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, stop in
        if runs.count >= 100_000 { failure = InspectError.invalid("DOC attribute run limit"); stop.pointee = true; return }
        var fields: [String: Any] = ["range": [range.location, range.length]]
        for (key, attribute) in attrs {
            if let font = attribute as? NSFont {
                fields[key.rawValue] = ["name": font.fontName, "size": font.pointSize, "traits": font.fontDescriptor.symbolicTraits.rawValue]
            } else if let c = attribute as? NSColor {
                fields[key.rawValue] = color(c)
            } else if let paragraph = attribute as? NSParagraphStyle {
                fields[key.rawValue] = ["alignment": paragraph.alignment.rawValue, "firstIndent": paragraph.firstLineHeadIndent,
                    "headIndent": paragraph.headIndent, "tailIndent": paragraph.tailIndent, "lineSpacing": paragraph.lineSpacing,
                    "spacing": paragraph.paragraphSpacing, "spacingBefore": paragraph.paragraphSpacingBefore,
                    "minLineHeight": paragraph.minimumLineHeight, "maxLineHeight": paragraph.maximumLineHeight,
                    "lineHeightMultiple": paragraph.lineHeightMultiple, "direction": paragraph.baseWritingDirection.rawValue,
                    "defaultTabInterval": paragraph.defaultTabInterval, "lineBreakMode": paragraph.lineBreakMode.rawValue,
                    "hyphenation": paragraph.hyphenationFactor, "tightening": paragraph.tighteningFactorForTruncation,
                    "tabs": paragraph.tabStops.map { ["alignment": $0.alignment.rawValue, "location": $0.location] },
                    "lists": paragraph.textLists.map { ["format": $0.markerFormat.rawValue, "start": $0.startingItemNumber] },
                    "tables": paragraph.textBlocks.compactMap { block -> [String: Any]? in
                        guard let b = block as? NSTextTableBlock else { unknown.insert("non-table text block"); return nil }
                        return ["row": b.startingRow, "column": b.startingColumn, "rowSpan": b.rowSpan, "columnSpan": b.columnSpan,
                                "columns": b.table.numberOfColumns, "layout": b.table.layoutAlgorithm.rawValue,
                                "background": b.backgroundColor.map(color) ?? []]
                    }]
            } else if let attachment = attribute as? NSTextAttachment {
                let name = "attachment:\(pictures.count)"
                guard pictures.count < 4096, let data = attachment.fileWrapper?.regularFileContents ?? attachment.image?.tiffRepresentation else {
                    failure = InspectError.invalid("Unreadable or over-limit DOC attachment"); stop.pointee = true; return
                }
                imageBytes += data.count
                guard imageBytes <= 64 * 1024 * 1024,
                      let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) else {
                    failure = InspectError.invalid("Unsupported or over-limit DOC image attachment"); stop.pointee = true; return
                }
                pictures.append(["name": name, "mediaType": type as String, "data": data.base64EncodedString()])
                fields[key.rawValue] = name
            } else if let url = attribute as? URL { fields[key.rawValue] = url.absoluteString
            } else if let text = attribute as? String { fields[key.rawValue] = text
            } else if let number = attribute as? NSNumber { fields[key.rawValue] = number
            } else { unknown.insert(key.rawValue) }
        }
        runs.append(fields)
    }
    if let failure { throw failure }
    return ["reader": "Apple-AppKit-DOC-importer", "coverage": ["text", "imported attribute runs and exposed links/tables/lists", "decoded image attachments"],
            "textParts": ["document": value.string], "structure": ["runs": runs], "pictures": pictures, "opaqueParts": [:],
            "uninspected": unknown.sorted(),
            "limits": ["No Word pagination/rendering, macros or legacy drawing/form fidelity proof; importer may not expose every DOC feature."] + unknown.sorted().map { "Unexposed native attribute: \($0)" }]
}

func pdfInfo(_ path: String) throws -> [String: Any] {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        throw InspectError.invalid("PDFKit cannot read this PDF")
    }
    var pages = [[String: Any]]()
    for index in 0..<doc.pageCount {
        guard let page = doc.page(at: index) else { throw InspectError.invalid("Missing PDF page") }
        let rect = page.bounds(for: .mediaBox)
        pages.append(["width": rect.width, "height": rect.height, "text": page.string ?? ""])
    }
    return ["pageCount": doc.pageCount, "pages": pages]
}

// Resolve PDF objects rather than comparing object numbers or compressed appearance bytes.
final class AnnotationObjects {
    var references: [CGPDFDictionaryRef: String] = [:]
    var nodes = 0
    var bytes = 0

    func value(_ object: CGPDFObjectRef, depth: Int = 0) throws -> Any {
        nodes += 1
        guard nodes <= 100_000, depth <= 32 else { throw InspectError.invalid("PDF annotation object limit") }
        switch CGPDFObjectGetType(object) {
        case .null: return NSNull()
        case .boolean:
            var v: CGPDFBoolean = 0; CGPDFObjectGetValue(object, .boolean, &v); return v != 0
        case .integer:
            var v: CGPDFInteger = 0; CGPDFObjectGetValue(object, .integer, &v); return v
        case .real:
            var v: CGPDFReal = 0; CGPDFObjectGetValue(object, .real, &v)
            guard v.isFinite else { throw InspectError.invalid("Nonfinite PDF annotation number") }; return v
        case .name:
            var v: UnsafePointer<CChar>?; CGPDFObjectGetValue(object, .name, &v)
            return ["name": v.map { String(cString: $0) } ?? ""]
        case .string:
            var v: CGPDFStringRef?; CGPDFObjectGetValue(object, .string, &v)
            guard let v else { throw InspectError.invalid("Invalid PDF annotation string") }
            let count = CGPDFStringGetLength(v); bytes += count
            guard bytes <= 8 * 1024 * 1024 else { throw InspectError.invalid("PDF annotation byte limit") }
            // Hex preserves binary strings, encodings and trailing data without lossy conversion.
            return ["stringBytes": Data(bytes: CGPDFStringGetBytePtr(v)!, count: count).base64EncodedString()]
        case .array:
            var v: CGPDFArrayRef?; CGPDFObjectGetValue(object, .array, &v)
            guard let v, CGPDFArrayGetCount(v) <= 10_000 else { throw InspectError.invalid("PDF annotation array limit") }
            return try (0..<CGPDFArrayGetCount(v)).map { index -> Any in
                var item: CGPDFObjectRef?
                guard CGPDFArrayGetObject(v, index, &item), let item else { throw InspectError.invalid("Invalid PDF annotation array") }
                return try value(item, depth: depth + 1)
            }
        case .dictionary:
            var v: CGPDFDictionaryRef?; CGPDFObjectGetValue(object, .dictionary, &v)
            guard let v else { throw InspectError.invalid("Invalid PDF annotation dictionary") }
            if let reference = references[v] { return ["reference": reference] }
            return try dictionary(v, depth: depth + 1)
        case .stream:
            var v: CGPDFStreamRef?; CGPDFObjectGetValue(object, .stream, &v)
            var format = CGPDFDataFormat.raw
            guard let v, let dict = CGPDFStreamGetDictionary(v), let data = CGPDFStreamCopyData(v, &format) as Data? else { throw InspectError.invalid("Unreadable PDF annotation stream") }
            bytes += data.count
            guard bytes <= 8 * 1024 * 1024 else { throw InspectError.invalid("PDF annotation byte limit") }
            return ["dictionary": try dictionary(dict, depth: depth + 1, excluding: ["Length", "Filter", "DecodeParms"]),
                    "dataFormat": format.rawValue, "decodedSize": data.count, "decodedSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        @unknown default: throw InspectError.invalid("Unsupported PDF annotation object")
        }
    }

    func dictionary(_ dict: CGPDFDictionaryRef, depth: Int = 0, excluding: Set<String> = []) throws -> [String: Any] {
        guard depth <= 32, CGPDFDictionaryGetCount(dict) <= 10_000 else { throw InspectError.invalid("PDF annotation dictionary limit") }
        var result: [String: Any] = [:], failure: Error?
        CGPDFDictionaryApplyBlock(dict, { key, object, _ in
            let name = String(cString: key)
            if !excluding.contains(name) {
                do { result[name] = try self.value(object, depth: depth + 1) }
                catch { failure = error; return false }
            }
            return true
        }, nil)
        if let failure { throw failure }
        return result
    }
}

func pdfAnnotations(_ path: String) throws -> [String: Any] {
    guard let doc = CGPDFDocument(URL(fileURLWithPath: path) as CFURL), let catalog = doc.catalog, !doc.isEncrypted,
          (1...256).contains(doc.numberOfPages) else { throw InspectError.invalid("Invalid, encrypted or over-limit PDF annotations") }
    let reader = AnnotationObjects()
    var pageAnnotations = [[CGPDFDictionaryRef]]()
    for index in 1...doc.numberOfPages {
        guard let page = doc.page(at: index), let dict = page.dictionary else { throw InspectError.invalid("Missing PDF page") }
        reader.references[dict] = "page:\(index)"
        var array: CGPDFArrayRef?, annotations = [CGPDFDictionaryRef]()
        if CGPDFDictionaryGetArray(dict, "Annots", &array), let array {
            guard CGPDFArrayGetCount(array) <= 4096 else { throw InspectError.invalid("PDF annotation count limit") }
            for at in 0..<CGPDFArrayGetCount(array) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, at, &annotation), let annotation else { throw InspectError.invalid("Invalid PDF annotation entry") }
                annotations.append(annotation)
                reader.references[annotation] = "annotation:\(index):\(at)"
            }
        } else {
            var invalid: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dict, "Annots", &invalid) { throw InspectError.invalid("Invalid PDF Annots array") }
        }
        pageAnnotations.append(annotations)
    }
    let pages = try pageAnnotations.map { annotations in
        try annotations.map { dict -> [String: Any] in
            var appearance: CGPDFObjectRef?
            let properties = try reader.dictionary(dict, excluding: ["AP"])
            let ap: Any = CGPDFDictionaryGetObject(dict, "AP", &appearance) ? try reader.value(appearance!) : NSNull()
            return ["properties": properties, "appearance": ap]
        }
    }
    var form: CGPDFDictionaryRef?
    let formInfo: Any = CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form) ? try reader.dictionary(form!) : NSNull()
    return ["pages": pages, "form": formInfo, "annotationVersion": 1, "reader": "CoreGraphics-object-readback"]
}

func pdfSize(_ page: CGPDFPage) throws -> CGSize {
    let box = page.getBoxRect(.mediaBox)
    guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
        throw InspectError.invalid("Invalid PDF media box")
    }
    let rotation = ((page.rotationAngle % 360) + 360) % 360
    return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
}

func pdfPixels(_ page: CGPDFPage, width: Int, height: Int) throws -> [UInt8] {
    let size = try pdfSize(page)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // getDrawingTransform only scales down, so apply the 144-DPI scale explicitly.
        context.scaleBy(x: 2, y: 2)
        let rect = CGRect(origin: .zero, size: size)
        context.clip(to: rect)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return true
    }
    guard ok else { throw InspectError.invalid("Cannot create PDF pixel context") }
    return bytes
}

func annotatedPixels(_ path: String, page: Int, program: String, width: Int, height: Int) throws -> [UInt8] {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("annotations-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let prefix = folder.appendingPathComponent("page")
    // Foundation Process creates a separate process group on macOS. Inherit this
    // group so the Python supervisor also kills Poppler on timeout/cancellation.
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw InspectError.invalid("Cannot initialize renderer process") }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd: Int32 in 0...2 {
        guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) == 0 else {
            throw InspectError.invalid("Cannot redirect renderer streams")
        }
    }
    let arguments = [program, "-r", "144", "-f", String(page), "-l", String(page), "-singlefile", "-png", path, prefix.path]
    var argv = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    let code = posix_spawn(&pid, program, &actions, nil, &argv, environ)
    guard code == 0 else { throw InspectError.invalid("Cannot launch annotation renderer: \(code)") }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        if errno != EINTR { throw InspectError.invalid("Cannot wait for annotation renderer") }
    }
    guard status == 0 else { throw InspectError.invalid("Poppler annotation rendering failed, wait status: \(status)") }
    let (w, h, decoded) = try pixels(source(prefix.path + ".png"), 0)
    guard w <= width, h <= height else { throw InspectError.invalid("Poppler annotation canvas exceeds checked media box") }
    if w == width && h == height { return decoded }
    var padded = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<h { padded.replaceSubrange(y * width * 4..<y * width * 4 + w * 4, with: decoded[y * w * 4..<(y + 1) * w * 4]) }
    return padded
}

func comparePdfs(_ left: String, _ right: String, annotationRenderer: String? = nil) throws -> [String: Any] {
    let annotations = annotationRenderer != nil
    guard let a = CGPDFDocument(URL(fileURLWithPath: left) as CFURL),
          let b = CGPDFDocument(URL(fileURLWithPath: right) as CFURL) else {
        throw InspectError.invalid("Core Graphics cannot read this PDF")
    }
    guard a.numberOfPages == b.numberOfPages else { return ["sameGeometry": false] }
    guard (1...256).contains(a.numberOfPages) else { throw InspectError.invalid("PDF raster inspection exceeds 256-page limit") }
    let ka = annotations ? PDFDocument(url: URL(fileURLWithPath: left)) : nil
    let kb = annotations ? PDFDocument(url: URL(fileURLWithPath: right)) : nil
    if annotations && (ka?.pageCount != a.numberOfPages || kb?.pageCount != b.numberOfPages) {
        throw InspectError.invalid("PDFKit annotation page count mismatch")
    }
    var scores = [[String: Any]]()
    for index in 1...a.numberOfPages {
        guard let x = a.page(at: index), let y = b.page(at: index) else { throw InspectError.invalid("Missing PDF page") }
        let sx = try pdfSize(x), sy = try pdfSize(y)
        guard abs(sx.width - sy.width) <= 1, abs(sx.height - sy.height) <= 1 else { return ["sameGeometry": false] }
        let width = ceil(max(sx.width, sy.width) * 2), height = ceil(max(sx.height, sy.height) * 2)
        guard width <= 8192, height <= 8192, width * height <= 16_000_000 else {
            throw InspectError.invalid("PDF raster inspection exceeds page pixel limit")
        }
        if annotations {
            let known = Set(["Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine",
                             "Highlight", "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "Popup", "Widget"])
            for (page, cgPage) in [(ka!.page(at: index - 1)!, x), (kb!.page(at: index - 1)!, y)] {
                var array: CGPDFArrayRef?
                let actual = CGPDFDictionaryGetArray(cgPage.dictionary!, "Annots", &array) ? CGPDFArrayGetCount(array!) : 0
                guard actual == page.annotations.count else { throw InspectError.invalid("PDFKit omitted an annotation") }
                guard page.annotations.count <= 4096 else { throw InspectError.invalid("PDF annotation count limit") }
                for annotation in page.annotations where annotation.shouldDisplay {
                    guard known.contains(annotation.type ?? "") || annotation.hasAppearanceStream else {
                        throw InspectError.invalid("Unsupported PDF annotation appearance: \(annotation.type ?? "unknown")")
                    }
                }
            }
        }
        if let program = annotationRenderer {
            scores.append(pixelScores(try annotatedPixels(left, page: index, program: program, width: Int(width), height: Int(height)),
                                      try annotatedPixels(right, page: index, program: program, width: Int(width), height: Int(height))))
        } else {
            scores.append(pixelScores(try pdfPixels(x, width: Int(width), height: Int(height)),
                                      try pdfPixels(y, width: Int(width), height: Int(height))))
        }
    }
    if annotations {
        return ["sameGeometry": true, "frames": scores, "dpi": 144, "annotationRasterVersion": 1,
                "background": "white", "renderer": "Poppler-page-with-annotations-mediaBox",
                "behavior": "Separate full-page composite with normal screen annotations; hidden/NoView excluded from raster but retained in object comparison. No interaction or scripts."]
    }
    return ["sameGeometry": true, "frames": scores, "dpi": 144, "rasterVersion": 2,
            "background": "white", "renderer": "CoreGraphics-mediaBox"]
}

do {
    let args = CommandLine.arguments
    guard args.count >= 3 else { throw InspectError.invalid("inspect image|pdf PATH; inspect compare LEFT RIGHT") }
    let result: [String: Any]
    switch args[1] {
    case "image": result = try imageInfo(args[2])
    case "doc": result = try documentInfo(args[2])
    case "pdf": result = try pdfInfo(args[2])
    case "pdf-annotations": result = try pdfAnnotations(args[2])
    case "ocr": result = ["text": try recognizedText(args[2])]
    case "compare":
        guard args.count == 4 else { throw InspectError.invalid("compare needs two paths") }
        result = try compareImages(args[2], args[3])
    case "pdf-compare":
        guard args.count == 4 else { throw InspectError.invalid("pdf-compare needs two paths") }
        result = try comparePdfs(args[2], args[3])
    case "pdf-annotation-compare":
        guard args.count == 5 else { throw InspectError.invalid("pdf-annotation-compare needs two PDF paths and a pinned pdftoppm path") }
        result = try comparePdfs(args[2], args[3], annotationRenderer: args[4])
    default: throw InspectError.invalid("Unknown inspection mode")
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
