import Foundation
import ImageIO
import CoreGraphics
import PDFKit
import CryptoKit

enum InspectError: Error { case invalid(String) }

func source(_ path: String) throws -> CGImageSource {
    guard let value = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        throw InspectError.invalid("ImageIO cannot read this image")
    }
    return value
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

func compareImages(_ left: String, _ right: String) throws -> [String: Any] {
    let a = try source(left), b = try source(right)
    let count = CGImageSourceGetCount(a)
    guard count > 0, count == CGImageSourceGetCount(b) else { return ["sameGeometry": false] }
    var scores = [[String: Any]]()
    for index in 0..<count {
        let (w, h, p) = try pixels(a, index), (bw, bh, q) = try pixels(b, index)
        guard w == bw, h == bh else { return ["sameGeometry": false] }
        var square = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<p.count {
            let d = Double(p[i]) - Double(q[i]); square += d * d
        }
        for i in stride(from: 0, to: p.count, by: 4) {
            let x = 0.2126 * Double(p[i]) + 0.7152 * Double(p[i+1]) + 0.0722 * Double(p[i+2])
            let y = 0.2126 * Double(q[i]) + 0.7152 * Double(q[i+1]) + 0.0722 * Double(q[i+2])
            sx += x; sy += y; sxx += x*x; syy += y*y; sxy += x*y
        }
        let n = Double(w*h), mx = sx/n, my = sy/n
        let vx = max(0, sxx/n-mx*mx), vy = max(0, syy/n-my*my), cov = sxy/n-mx*my
        let ssim = ((2*mx*my+6.5025)*(2*cov+58.5225))/((mx*mx+my*my+6.5025)*(vx+vy+58.5225))
        let mse = square / Double(p.count)
        scores.append(["psnr": mse == 0 ? 99.0 : 10*log10(65025/mse), "ssim": ssim])
    }
    return ["sameGeometry": true, "frames": scores]
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

do {
    let args = CommandLine.arguments
    guard args.count >= 3 else { throw InspectError.invalid("inspect image|pdf PATH; inspect compare LEFT RIGHT") }
    let result: [String: Any]
    switch args[1] {
    case "image": result = try imageInfo(args[2])
    case "pdf": result = try pdfInfo(args[2])
    case "compare":
        guard args.count == 4 else { throw InspectError.invalid("compare needs two paths") }
        result = try compareImages(args[2], args[3])
    default: throw InspectError.invalid("Unknown inspection mode")
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
