// Ports of RhwpConverter.cs, HwpxConverter.cs, DocxWriterConverter.cs and the approved Unhwp replacement.
import Foundation

public final class RhwpConverter: Converter {
    public let id = "rhwp", displayName = "rhwp", maxParallelism = 2
    public let edges = [
        ConversionEdge("hwp", "pdf"), ConversionEdge("hwpx", "pdf"), ConversionEdge("hwp", "hwpx"),
        ConversionEdge("hwpx", "hwp"),
    ]
    private var executable: String?
    public init() {}
    public func status() -> EngineStatus {
        executable = Self.locate()
        return executable.map { .available(detail: $0, version: EngineVersions.component("rhwp")) }
            ?? .unavailable("engine.reason.not_installed")
    }
    static func locate() -> String? {
        EngineEnvironment.findBundled("rhwp").flatMap { EngineEnvironment.firstExisting(FilePath.combine($0, "rhwp")) }
    }
    static func run(_ input: String, _ format: String, _ work: String, _ progress: ProgressHandler?) async throws
        -> String
    {
        guard let exe = locate() else { throw ConversionError("rhwp was not found.") }
        return try await run(exe, input, format, work, progress)
    }
    private static func run(
        _ exe: String, _ input: String, _ format: String, _ work: String, _ progress: ProgressHandler?
    ) async throws -> String {
        let temp = FilePath.combine(work, "rhwp-" + DocumentXML.guid() + "." + format)
        let arguments: [String]
        switch format {
        case "pdf": arguments = ["export-pdf", input, "-o", temp]
        case "hwpx": arguments = ["export-hwpx", input, temp]
        case "hwp": arguments = ["convert", input, temp]
        default: throw ConversionError(format)
        }
        progress?(0.1)
        let estimate = ProgressEstimate.start(progress, typical: 1.5)
        defer { estimate.stop() }
        let result = try await ProcessRunner.run(exe, arguments, timeout: 120)
        guard FileManager.default.fileExists(temp),
            ((try? FileManager.default.attributesOfItem(atPath: temp)[.size] as? NSNumber)?.intValue ?? 0) > 0
        else {
            throw ConversionError("rhwp failed (exit \(result.exitCode)). \(DocumentXML.trim(result.standardError))")
        }
        return temp
    }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let exe = executable ?? Self.locate() else { throw ConversionError("rhwp was not found.") }
        let temp = try await Self.run(exe, step.inputPath, step.to, step.workDirectory, progress)
        guard let target = try step.output.allocate(step.to) else { return [] }
        try DocumentXML.moveReplacing(temp, target)
        progress?(1)
        return [target]
    }
}

public final class HwpxConverter: Converter {
    public let id = "hwpx-writer", displayName = "HWPX writer (built-in)", maxParallelism = 0
    private var pandoc: Bool?
    public init() {}
    public var edges: [ConversionEdge] {
        DocumentReaders.formats(pandoc ?? (PandocConverter.locate() != nil)).filter { $0 != "hwpx" }.map {
            ConversionEdge($0, "hwpx", $0 == "pdf" ? 10 + DocumentReaders.pdfPenalty : 10)
        }
    }
    public func status() -> EngineStatus {
        let exe = PandocConverter.locate()
        pandoc = exe != nil
        let builtIn = DocumentReaders.builtInFormats.map { $0.uppercased() }.joined(separator: ", ")
        let extra = DocumentReaders.pandocFormats.map { $0.uppercased() }.joined(separator: ", ")
        return .available(
            detail: exe.map { "\(builtIn); \(extra) with Pandoc (\($0))" }
                ?? "\(builtIn) → HWPX. \(extra) need Pandoc.", version: EngineVersions.builtIn)
    }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        progress?(0.1)
        let doc = try await DocumentReaders.readAsync(step.inputPath, step.from, step.workDirectory)
        progress?(0.6)
        guard let output = try step.output.allocate("hwpx") else { return [] }
        try HwpxWriter.write(doc, output)
        progress?(1)
        return [output]
    }
    static func textDocument(_ data: Data) -> HDocument { DocumentReaders.textDocument(data) }
    static func decodeText(_ data: Data) -> String { TextEncodings.decodeText(data) }
}

public final class DocxWriterConverter: Converter {
    public let id = "docx-writer", displayName = "DOCX writer (built-in)", maxParallelism = 0
    public let edges = DocumentReaders.builtInFormats.filter { !["docx", "docm", "dotx", "dotm"].contains($0) }.map {
        ConversionEdge($0, "docx", $0 == "pdf" ? 8 + DocumentReaders.pdfPenalty : 8)
    }
    public init() {}
    public func status() -> EngineStatus {
        .available(
            detail: edges.map { $0.from.uppercased() }.joined(separator: ", ") + " → DOCX",
            version: EngineVersions.builtIn)
    }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        progress?(0.1)
        let doc = try await DocumentReaders.readAsync(step.inputPath, step.from, step.workDirectory)
        progress?(0.6)
        guard let output = try step.output.allocate("docx") else { return [] }
        try Task.checkCancellation()
        try DocxWriter.write(doc, output)
        progress?(1)
        return [output]
    }
}

public final class UnhwpConverter: Converter {
    public let id = "unhwp", displayName = "HWP text reader (built-in)", maxParallelism = 0
    public let edges = [
        ConversionEdge("hwp", "txt"), ConversionEdge("hwpx", "txt"), ConversionEdge("hwp", "md"),
        ConversionEdge("hwpx", "md"), ConversionEdge("hwp", "html", 14), ConversionEdge("hwpx", "html", 14),
    ]
    public init() {}
    public func status() -> EngineStatus {
        .available(
            detail: RhwpConverter.locate() == nil ? "HWPX → TXT, MD, HTML. HWP needs rhwp." : nil,
            version: EngineVersions.builtIn)
    }
    // Converter's shared status has no input format; callers checking a direct HWP edge can use this overload.
    public func status(_ sourceFormat: String) -> EngineStatus {
        sourceFormat == "hwp" && RhwpConverter.locate() == nil ? .unavailable("engine.reason.not_installed") : status()
    }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        let input =
            step.from == "hwp"
            ? try await RhwpConverter.run(step.inputPath, "hwpx", step.workDirectory, nil) : step.inputPath
        let doc = try HwpxReader.read(input, FilePath.combine(step.workDirectory, "media-" + DocumentXML.guid()))
        try Task.checkCancellation()
        progress?(0.5)
        // Keep image content in the single allocated output; extracted work files are deleted after the job.
        var imageSources: [String: String] = [:]
        if step.to == "md" || step.to == "html" {
            for image in HDocumentWalker.images(doc) where imageSources[image.path] == nil {
                let ext = FilePath.extension(image.path).lowercased()
                let mime = [
                    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
                    ".bmp": "image/bmp", ".svg": "image/svg+xml",
                ][ext]
                let bytes =
                    try mime == nil
                    ? ImageSupport.pngData(image.path) : Data(contentsOf: URL(fileURLWithPath: image.path))
                imageSources[image.path] = "data:\(mime ?? "image/png");base64," + bytes.base64EncodedString()
            }
        }
        let content: String
        switch step.to {
        case "txt": content = PlainTextWriter.write(doc)
        case "md":
            doc.title = nil  // Unhwp used IncludeFrontmatter = false for Markdown exports.
            content = MarkdownWriter.write(doc) { imageSources[$0] }
        case "html":
            let body = XhtmlWriter.write(doc, XhtmlOptions(imageSource: { imageSources[$0] })).map(\.body).joined()
            let title = doc.title ?? FilePath.fileNameWithoutExtension(step.inputPath)
            content = Self.htmlPage(title, body)
        default: throw ConversionError(step.to)
        }
        guard let path = try step.output.allocate(step.to) else { return [] }
        var data = Data()
        if step.to == "txt" { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: content.utf8)
        try data.write(to: URL(fileURLWithPath: path))
        progress?(1)
        return [path]
    }
    private static func htmlPage(_ title: String, _ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(XhtmlWriter.escape(title))</title>
        <style>body{font-family:'Noto Sans KR','Malgun Gothic','Microsoft YaHei',sans-serif;max-width:860px;margin:2rem auto;line-height:1.7;padding:0 1rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px}pre,code{background:#f4f3f8;border-radius:4px}pre{padding:.6rem .8rem;overflow:auto}img{max-width:100%}blockquote{margin-left:0;padding-left:1rem;border-left:3px solid #ccc;color:#555}</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
