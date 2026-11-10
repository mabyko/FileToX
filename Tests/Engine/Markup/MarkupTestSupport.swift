// Shared helpers of the Markup tests: scratch folders, test pictures and the canonical HDocument dump. The dump is
// the same text the Filee comparison harness prints for the C# readers, so outputs can be diffed line by line.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FileToXEngineKit

enum MarkupTestSupport {
    /// A new empty folder under the temporary directory.
    static func newFolder() throws -> String {
        let path = FilePath.combine(NSTemporaryDirectory(), "ftx-markup-\(UUID().uuidString)")
        try FileManager.default.createDirectoryIfNeeded(path)
        return path
    }

    /// A solid-colour PNG (Filee's tests use `new MagickImage(color, w, h)`).
    static func png(_ width: Int, _ height: Int, red: UInt8 = 0, green: UInt8 = 128, blue: UInt8 = 128) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Conversion jobs

    /// Every registered engine, as the helper builds them.
    static func converters(excluding: [String] = []) -> [Converter] {
        let data = FilePath.combine(NSTemporaryDirectory(), "ftx-markup-engines")
        return EngineRegistry.createAll(EngineEnvironment(dataDirectory: data)).filter { !excluding.contains($0.id) }
    }

    static func preset(_ target: String, _ change: (inout Preset) -> Void = { _ in }) -> Preset {
        var preset = Preset()
        preset.targetFormat = target
        change(&preset)
        return preset
    }

    /// Runs one job through the real queue and engines (Filee's `EngineFixture.ConvertAsync`).
    static func run(_ inputs: [String], _ preset: Preset, converters: [Converter] = converters()) async -> ConversionJob {
        let queue = JobQueue(ConverterCatalog(converters), pdfMerger: EngineRegistry.findPdfMerger(converters),
                             combiner: EngineRegistry.findFileCombiner(converters), tiffMerger: EngineRegistry.findTiffMerger(converters))
        let job = ConversionJob(inputs, preset, "Test")
        await queue.run(job)
        return job
    }

    /// The single output of a job that must complete.
    static func convert(_ input: String, _ target: String, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let job = await run([input], preset(target))
        XCTAssertEqual(job.state, .completed, job.files.map { "\($0.errorKey ?? "") \($0.errorDetail ?? "")" }.joined(separator: "; "), file: file, line: line)
        return try XCTUnwrap(job.outputs.count == 1 ? job.outputs.first : nil, "outputs: \(job.outputs)", file: file, line: line)
    }

    /// A Pandoc copy for tests: $FILETOX_PANDOC, the development copy of the FileToX checkout, or one on the Mac.
    static func pandocFolder() -> String? {
        let development = ProcessInfo.processInfo.environment["FILETOX_PANDOC"]
            ?? FileManager.default.currentDirectoryPath + "/build/optional-engines/osx-arm64/pandoc"
        return EngineEnvironment.folderWithPrograms("pandoc", development) ?? EngineEnvironment.systemCopyFolder("pandoc")
    }

    // MARK: Canonical dump (same format as the harness' Dump class)

    static func dump(_ document: HDocument) -> String {
        var dumper = Dumper()
        dumper.output += "TITLE \(quote(document.title))\n"
        for section in document.sections {
            dumper.output += "SECTION\n"
            dumper.blocks(section.blocks, depth: 1)
        }
        dumper.numberings()
        return dumper.output
    }

    /// Blocks at depth 0 followed by their numberings (the harness' `htmlparse` output after TITLE / LANG).
    static func dump(blocks: [HBlock]) -> String {
        var dumper = Dumper()
        dumper.blocks(blocks, depth: 0)
        dumper.numberings()
        return dumper.output
    }

    static func quote(_ text: String?) -> String {
        guard let text else { return "null" }
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04X", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    private static func name<T>(_ value: T) -> String {
        let text = String(describing: value)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func number(_ value: Int?) -> String { value.map(String.init) ?? "null" }

    private static func number(_ value: Double) -> String {
        value == value.rounded(.down) && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    static func char(_ format: HCharFormat) -> String {
        var parts: [String] = []
        if let value = format.bold { parts.append("bold=" + flag(value)) }
        if let value = format.italic { parts.append("italic=" + flag(value)) }
        if let value = format.underline { parts.append("underline=" + flag(value)) }
        if let value = format.strike { parts.append("strike=" + flag(value)) }
        if let value = format.superscript { parts.append("sup=" + flag(value)) }
        if let value = format.subscript { parts.append("sub=" + flag(value)) }
        if let value = format.size { parts.append("size=\(value)") }
        if let value = format.font { parts.append("font=" + quote(value)) }
        if let value = format.eastAsianFont { parts.append("eastAsian=" + quote(value)) }
        if let value = format.color { parts.append("color=" + value) }
        if let value = format.shade { parts.append("shade=" + value) }
        if let value = format.spacing { parts.append("spacing=\(value)") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func para(_ format: HParaFormat) -> String {
        var parts: [String] = []
        if let value = format.align { parts.append("align=" + name(value)) }
        if let value = format.left { parts.append("left=\(value)") }
        if let value = format.right { parts.append("right=\(value)") }
        if let value = format.firstLine { parts.append("firstLine=\(value)") }
        if let value = format.before { parts.append("before=\(value)") }
        if let value = format.after { parts.append("after=\(value)") }
        if let value = format.lineSpacing { parts.append("lineSpacing=\(name(value.kind)):\(value.value)") }
        if let value = format.keepWithNext { parts.append("keepWithNext=" + flag(value)) }
        if let value = format.keepLines { parts.append("keepLines=" + flag(value)) }
        if let value = format.widowOrphan { parts.append("widowOrphan=" + flag(value)) }
        if let tabs = format.tabs, !tabs.isEmpty {
            parts.append("tabs=" + tabs.map { "\($0.position):\(name($0.kind)):\($0.leader)" }.joined(separator: "|"))
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func border(_ border: HBorder) -> String { "\(name(border.style)):\(number(border.widthMm)):\(border.color)" }

    private static func borders(_ borders: HBorders?) -> String {
        guard let borders else { return "null" }
        return "[\(border(borders.left)) \(border(borders.right)) \(border(borders.top)) \(border(borders.bottom))]"
    }

    private struct Dumper {
        var output = ""
        var numberingList: [HNumbering] = []

        mutating func line(_ depth: Int, _ text: String) {
            output += String(repeating: " ", count: depth * 2) + text + "\n"
        }

        mutating func blocks(_ blocks: [HBlock], depth: Int) {
            for block in blocks {
                if let paragraph = block as? HParagraph {
                    var head = "P"
                    if paragraph.headingLevel != 0 { head += " h=\(paragraph.headingLevel)" }
                    head += " fmt=" + para(paragraph.format)
                    if !paragraph.markFormat.isEmpty { head += " mark=" + char(paragraph.markFormat) }
                    if let list = paragraph.list {
                        var index = numberingList.firstIndex { $0 === list.numbering } ?? -1
                        if index < 0 { numberingList.append(list.numbering); index = numberingList.count - 1 }
                        head += " list=\(index)/\(list.level)/\(list.numbered ? 1 : 0)"
                    }
                    if paragraph.pageBreakBefore { head += " pb" }
                    if paragraph.columnBreakBefore { head += " cb" }
                    line(depth, head)
                    inlines(paragraph.inlines, depth: depth + 1)
                } else if let table = block as? HTable {
                    let widths = table.columnWidths.map { "[" + $0.map(String.init).joined(separator: ",") + "]" } ?? "null"
                    let relative = table.relativeWidths.map { "[" + $0.map(number).joined(separator: ",") + "]" } ?? "null"
                    let margin = table.cellMargin.map { "[\($0.left),\($0.right),\($0.top),\($0.bottom)]" } ?? "null"
                    line(depth, "TABLE cols=\(table.columnCount) widths=\(widths) rel=\(relative) align=\(name(table.align)) indent=\(table.indent) margin=\(margin) borders=\(MarkupTestSupport.borders(table.borders))")
                    if !table.caption.isEmpty {
                        line(depth + 1, "CAPTION")
                        self.blocks(table.caption, depth: depth + 2)
                    }
                    for row in table.rows {
                        line(depth + 1, "ROW header=\(flag(row.header)) height=\(number(row.height))")
                        for cell in row.cells {
                            line(depth + 2, "CELL col=\(cell.column) rs=\(cell.rowSpan) cs=\(cell.colSpan) va=\(name(cell.verticalAlign)) fill=\(cell.fill ?? "null") borders=\(MarkupTestSupport.borders(cell.borders))")
                            self.blocks(cell.blocks, depth: depth + 3)
                        }
                    }
                } else {
                    line(depth, "BLOCK \(type(of: block))")
                }
            }
        }

        mutating func inlines(_ inlines: [HInline], depth: Int) {
            for inline in inlines {
                switch inline {
                case let text as HText: line(depth, "T \(quote(text.text)) \(char(text.format))")
                case let lineBreak as HLineBreak: line(depth, "BR \(char(lineBreak.format))")
                case let tab as HTab: line(depth, "TAB \(char(tab.format))")
                case let link as HLink:
                    line(depth, "LINK \(quote(link.target))")
                    self.inlines(link.content, depth: depth + 1)
                case let bookmark as HBookmark: line(depth, "BM \(quote(bookmark.name))")
                case let note as HNote:
                    line(depth, "NOTE endnote=\(flag(note.endnote))")
                    blocks(note.blocks, depth: depth + 1)
                case let image as HImage:
                    line(depth, "IMG \(quote(image.path)) w=\(number(image.width)) h=\(number(image.height))\(image.anchor == nil ? "" : " anchored")")
                case let shape as HShape:
                    line(depth, "SHAPE \(name(shape.kind)) w=\(shape.width) h=\(shape.height) line=\(border(shape.line)) fill=\(shape.fill ?? "null")")
                default:
                    line(depth, "INLINE \(type(of: inline))")
                }
            }
        }

        mutating func numberings() {
            for (index, numbering) in numberingList.enumerated() {
                output += "NUMBERING \(index): " + numbering.levels.map { "\($0.format),\($0.text),\($0.start),\($0.bullet ? 1 : 0)" }.joined(separator: "; ") + "\n"
            }
        }
    }
}
