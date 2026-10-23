// Port of Filee.Engines/Text/MarkdownConverter.cs: Markdown → HTML and plain text, in-process (Markdig-compatible
// parser in Markdown/), so Markdown works without any optional engine. The HTML also serves as an intermediate step
// (Markdown → HTML → PDF / DOCX through LibreOffice), so local images get absolute file URIs whenever the page is
// written away from the Markdown file.

import Foundation

/// Markdown to HTML and TXT without external programs.
public final class MarkdownConverter: Converter {
    public let id = "markdown"
    public let displayName = "Markdown (built-in)"
    public let maxParallelism = 0
    /// Cheaper than Pandoc's Markdown edges, so the built-in path wins for HTML and TXT.
    public let edges = [ConversionEdge("md", "html", 4), ConversionEdge("md", "txt", 5)]

    public init() {}

    public func status() -> EngineStatus { .available(version: EngineVersions.builtIn) }

    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        try Task.checkCancellation()
        let markdown = TextEncodings.decodeText(try Data(contentsOf: URL(fileURLWithPath: step.inputPath)))
        progress?(0.3)
        guard let output = try step.output.allocate(step.to) else { return [] }
        let content: String
        switch step.to {
        case "html": content = try Self.toHtml(markdown, FilePath.fullPath(step.inputPath), output)
        case "txt": content = try Markdown.toPlainText(markdown, MarkdownReader.pipeline)
        default: throw ConversionError(step.to)
        }
        try Task.checkCancellation()
        var data = Data(step.to == "txt" ? [0xEF, 0xBB, 0xBF] : [])
        data.append(contentsOf: content.utf8)
        try data.write(to: URL(fileURLWithPath: output))
        progress?(1)
        return [output]
    }

    /// A complete HTML page for the Markdown file at `inputPath`, written to `outputPath`.
    static func toHtml(_ markdown: String, _ inputPath: String, _ outputPath: String) throws -> String {
        let document = try Markdown.parse(markdown, MarkdownReader.pipeline)
        let inputFolder = FilePath.directoryName(inputPath) ?? ""
        // A staged output (JobQueue) is compared by where it will end up.
        let outputFolder = FilePath.directoryName(FilePath.fullPath(OutputCommit.finalPath(of: outputPath))) ?? ""
        if !MarkupConvert.equalsOrdinalIgnoreCase(inputFolder, outputFolder) {
            // Relative image paths would break away from the Markdown file: point them at the original files.
            for image in document.inlineDescendants(Markdown.LinkInline.self) where image.isImage {
                if let path = MarkdownReader.resolveImage(image.url, inputFolder) { image.url = MarkupConvert.fileUri(path) }
            }
        }
        let body = try Markdown.render(document, MarkdownReader.pipeline)
        let title: String
        if let heading = document.blockDescendants(Markdown.HeadingBlock.self).first, let inline = heading.inline {
            title = inline.findDescendants(Markdown.LiteralInline.self).map(\.content.description).joined()
        } else {
            title = FilePath.fileNameWithoutExtension(inputPath)
        }
        return htmlPage(title, body)
    }

    /// Wraps an HTML fragment into a readable, self-contained page (UTF-8, Korean / Chinese fonts).
    static func htmlPage(_ title: String, _ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(MarkupConvert.htmlEncode(title))</title>
        <style>body{font-family:'Noto Sans KR','Malgun Gothic','Microsoft YaHei',sans-serif;max-width:860px;margin:2rem auto;line-height:1.7;padding:0 1rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px}pre,code{background:#f4f3f8;border-radius:4px}pre{padding:.6rem .8rem;overflow:auto}img{max-width:100%}blockquote{margin-left:0;padding-left:1rem;border-left:3px solid #ccc;color:#555}</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
