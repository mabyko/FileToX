// Port of Filee.Engines/Office/PandocConverter.cs (with Vendor/Filee.patches/0002): general document conversions
// with Pandoc (GPL-2.0-or-later, a separate program: bundled/downloaded, the user's own copy or one on the Mac).
// Adds Markdown ↔ DOCX / ODT / RTF, HTML ↔ DOCX / ODT, and reStructuredText and LaTeX ↔ Markdown / HTML / DOCX /
// ODT (and → RTF, EPUB, TXT); Markdown → HTML / TXT / HWPX / DOCX is built in (MarkdownConverter, the HWPX and DOCX
// writers).

import Foundation

/// Markdown, HTML, DOCX, ODT, RTF, reStructuredText and LaTeX conversions through Pandoc.
public final class PandocConverter: Converter {
    private static let timeout: TimeInterval = 120

    private static let readers: [String: String] = [
        "md": "markdown", "html": "html", "docx": "docx", "odt": "odt", "rtf": "rtf", "rst": "rst", "tex": "latex",
    ]

    private static let writers: [String: String] = [
        "md": "gfm", "html": "html", "docx": "docx", "odt": "odt", "rtf": "rtf", "txt": "plain", "rst": "rst",
        "tex": "latex", "epub": "epub",
    ]

    /// reStructuredText and LaTeX: what Pandoc reads and writes well (no PDF, which would need a TeX engine).
    private static let markup = ["rst", "tex"]

    private var pandoc: String?

    public let id = "pandoc"
    public let displayName = "Pandoc"
    public let maxParallelism = 0

    public let edges: [ConversionEdge] = {
        var edges: [ConversionEdge] = []
        // Markdown in / out: only Pandoc does this.
        edges += ["docx", "odt", "html", "rtf"].map { ConversionEdge($0, "md") }
        edges += ["docx", "odt", "html", "rtf", "txt"].map { ConversionEdge("md", $0) }
        // Overlaps with LibreOffice (the fallback engine, which costs more).
        edges += ["docx", "odt"].map { ConversionEdge("html", $0, 14) }
        edges += ["docx", "odt"].map { ConversionEdge($0, "html", 14) }
        // reStructuredText and LaTeX in / out: only Pandoc does this.
        for markup in markup {
            for to in ["md", "html", "docx", "odt", "rtf", "epub", "txt", "rst", "tex"] where to != markup {
                edges.append(ConversionEdge(markup, to))
            }
        }
        for markup in markup {
            for source in ["md", "html", "docx", "odt"] { edges.append(ConversionEdge(source, markup)) }
        }
        return edges
    }()

    public init() {}

    public func status() -> EngineStatus {
        pandoc = Self.locate()
        guard let pandoc else { return .unavailable("engine.reason.not_installed") }
        return .available(detail: pandoc, version: EngineEnvironment.usesBundledCopy("pandoc") ? EngineVersions.component("pandoc") : nil)
    }

    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let pandoc = pandoc ?? Self.locate() else { throw ConversionError("Pandoc was not found.") }
        guard let output = try step.output.allocate(step.to) else { return [] }
        progress?(0.1)
        // Pandoc runs inside the folder the output is written to (the staging folder of JobQueue), so the media it
        // extracts ("<name>_files", linked relatively) is staged and committed with the output, never written into
        // the final folder. The input's folder stays the place relative resources are found.
        let input = FilePath.fullPath(step.inputPath)
        let folder = FilePath.directoryName(FilePath.fullPath(output)) ?? "/"
        guard let reader = Self.readers[step.from], let writer = Self.writers[step.to] else {
            throw ConversionError("The given key was not present in the dictionary.")
        }
        var arguments = [input, "-f", reader, "-t", writer, "-o", FilePath.fullPath(output),
                         "--resource-path=" + (FilePath.directoryName(input) ?? "")]
        if step.to == "html" || step.to == "tex" { arguments.append("--standalone") }
        if ["md", "html", "rst", "tex"].contains(step.to) {
            arguments.append("--extract-media=" + FilePath.fileNameWithoutExtension(output) + "_files")
        }
        let result: ProcessResult
        do {
            let estimate = ProgressEstimate.start(progress, typical: 1.5)
            defer { estimate.stop() }
            result = try await ProcessRunner.run(pandoc, arguments, timeout: Self.timeout, workingDirectory: folder)
        }
        if !FileManager.default.fileExists(output) {
            throw ConversionError("Pandoc failed (exit \(result.exitCode)). \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        progress?(1)
        return [output]
    }

    /// Uses the selected copy, a bundled copy, then the system installation.
    static func locate() -> String? {
        EngineEnvironment.ownProgram("pandoc", "pandoc.exe") ?? EngineEnvironment.bundledProgram("pandoc", "pandoc.exe")
            ?? EngineEnvironment.systemProgram("pandoc", "pandoc.exe")
    }
}
