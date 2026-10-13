#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Editable vector source for the approved radial-menu icon. Run from the repository root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let artwork = root.appendingPathComponent("docs/design/assets")
let info: [String: Any] = ["author": "xcode", "version": 1]

func writeJSON(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func gradient(_ first: UInt32, _ last: UInt32) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(first), color(last)] as CFArray, locations: [0, 1])!
}

func wedge(center: CGPoint, outer: CGFloat, inner: CGFloat, index: Int, count: Int, gap: CGFloat) -> CGPath {
    let span = 2 * CGFloat.pi / CGFloat(count)
    let start = CGFloat(index) * span - span / 2 - .pi / 2
    let end = start + span
    let outerInset = asin(gap / 2 / outer), innerInset = asin(gap / 2 / inner)
    let path = CGMutablePath()
    path.addArc(center: center, radius: outer, startAngle: start + outerInset, endAngle: end - outerInset, clockwise: false)
    path.addArc(center: center, radius: inner, startAngle: end - innerInset, endAngle: start + innerInset, clockwise: true)
    path.closeSubpath()
    return path
}

func master(dev: Bool) -> CGImage {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 8, y: -8)
    let background = CGPath(roundedRect: CGRect(x: 4, y: 4, width: 120, height: 120), cornerWidth: 27, cornerHeight: 27, transform: nil)
    context.saveGState()
    context.addPath(background); context.clip()
    context.drawLinearGradient(gradient(0xF5F6FA, 0xDFE4ED), start: .zero, end: CGPoint(x: 0, y: 128), options: [])
    context.restoreGState()
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.8)); context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: CGRect(x: 5, y: 5, width: 118, height: 118), cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.strokePath()
    for index in 0..<8 {
        let path = wedge(center: CGPoint(x: 64, y: 64), outer: 46, inner: 20, index: index, count: 8, gap: 1.7)
        if index == 1 {
            context.saveGState(); context.addPath(path); context.clip()
            context.drawLinearGradient(gradient(0x5BA8FF, 0x2355D8), start: .zero, end: CGPoint(x: 128, y: 128), options: [])
            context.restoreGState()
        } else {
            context.setFillColor(color(0x394150)); context.addPath(path); context.fillPath()
        }
    }
    if dev {
        let badge = CGMutablePath()
        badge.move(to: CGPoint(x: 84, y: 4)); badge.addLine(to: CGPoint(x: 97, y: 4))
        badge.addQuadCurve(to: CGPoint(x: 124, y: 31), control: CGPoint(x: 124, y: 4))
        badge.addLine(to: CGPoint(x: 124, y: 44)); badge.closeSubpath()
        context.setFillColor(color(0xFFA540)); context.addPath(badge); context.fillPath()
        context.setStrokeColor(color(0x713700)); context.setLineWidth(5); context.setLineCap(.round)
        context.move(to: CGPoint(x: 104, y: 15)); context.addLine(to: CGPoint(x: 112, y: 23)); context.strokePath()
    }
    return context.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

try writeJSON(["info": info], to: assets.appendingPathComponent("Contents.json"))
for (name, dev) in [("AppIcon", false), ("AppIcon-Dev", true)] {
    let image = master(dev: dev)
    try writePNG(image, size: 1024, to: artwork.appendingPathComponent("\(name).png"))
    var slots: [[String: Any]] = []
    // macOS asset-catalog slots: https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let filename = "icon-\(points)@\(scale)x.png"
            try writePNG(image, size: points * scale, to: assets.appendingPathComponent("\(name).appiconset/\(filename)"))
            slots.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
        }
    }
    try writeJSON(["images": slots, "info": info], to: assets.appendingPathComponent("\(name).appiconset/Contents.json"))
}

let menuURL = assets.appendingPathComponent("MenuBarIcon.imageset/MenuBarIcon.pdf")
try FileManager.default.createDirectory(at: menuURL.deletingLastPathComponent(), withIntermediateDirectories: true)
var box = CGRect(x: 0, y: 0, width: 18, height: 18)
let menu = CGContext(menuURL as CFURL, mediaBox: &box, nil)!
menu.beginPDFPage(nil)
menu.setFillColor(CGColor(gray: 0, alpha: 1))
for index in 0..<4 {
    menu.addPath(wedge(center: CGPoint(x: 9, y: 9), outer: 7.5, inner: 3.6, index: index, count: 4, gap: 0.825))
    menu.fillPath()
}
menu.endPDFPage(); menu.closePDF()
try writeJSON(["images": [["idiom": "universal", "filename": "MenuBarIcon.pdf"]], "info": info,
               "properties": ["template-rendering-intent": "template", "preserves-vector-representation": true]],
              to: menuURL.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Generated AppIcon, AppIcon-Dev and MenuBarIcon from the approved radial-menu design.")
