// Port of Filee.Engines/Vector/GhostscriptConverter.cs: PostScript and EPS with Ghostscript (AGPL-3.0, a separate
// program the user installs). EPS/PS → PDF with pdfwrite; PDF → EPS/PS with eps2write/ps2write; EPS/PS → PNG with
// pngalpha, which keeps a transparent background (through PDF the page would be drawn on white paper). Everything else
// (EPS → JPG, SVG → EPS, …) is planned through PDF or PNG by the route planner.

import Foundation
import PDFKit

/// EPS, PS and PostScript-based AI ↔ PDF through Ghostscript.
final class GhostscriptConverter: Converter {
    private static let timeout: TimeInterval = 5 * 60

    /// Environment variables Ghostscript would otherwise read from the user's system (extra options, resource and font
    /// search paths), so it behaves the same everywhere.
    private static let cleanEnvironment = ["GS_OPTIONS": "", "GS_LIB": "", "GS_FONTPATH": ""]

    private let lock = NSLock()
    private var executable: String?

    let id = "ghostscript"
    let displayName = "Ghostscript"
    let maxParallelism = 0

    let edges = [
        ConversionEdge("eps", "pdf"),
        ConversionEdge("ps", "pdf"),
        ConversionEdge("pdf", "eps"),
        ConversionEdge("pdf", "ps"),
        ConversionEdge("eps", "png"),
        ConversionEdge("ps", "png"),
    ]

    func status() -> EngineStatus {
        let found = Self.locate()
        lock.withLock { executable = found }
        guard let found else { return .unavailable("engine.reason.not_installed") }
        return .available(detail: found, version: EngineEnvironment.usesBundledCopy("ghostscript") ? EngineVersions.component("ghostscript") : nil)
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let gs = lock.withLock({ executable }) ?? Self.locate() else { throw ConversionError("Ghostscript is not installed.") }
        progress?(0.05)
        let written: [String] = switch step.to {
        case "pdf": try await toPdf(gs, step, progress)
        case "ps": try await toPostScript(gs, step, progress)
        case "eps": try await toEps(gs, step, progress)
        case "png": try await toPng(gs, step, progress)
        default: throw ConversionError("Ghostscript cannot write '\(step.to)'.")
        }
        progress?(1)
        return written
    }

    /// The user's own Ghostscript, the downloaded one, or one already on the Mac.
    static func locate() -> String? {
        EngineEnvironment.ownProgram("ghostscript", "gswin64c.exe") ?? EngineEnvironment.bundledProgram("ghostscript", "gswin64c.exe")
            ?? EngineEnvironment.systemProgram("ghostscript", "gswin64c.exe")
    }

    /// Converts PostScript (PS, EPS, PostScript-based Illustrator files) to PDF. EPS pages are cropped to the bounding
    /// box. Used by VectorConverter for AI files saved without PDF compatibility.
    static func convertToPdf(_ gs: String, _ input: String, _ output: String, crop: Bool, _ workDirectory: String,
                             _ progress: ProgressHandler? = nil) async throws {
        let scratch = try newScratch(workDirectory)
        let target = FilePath.combine(scratch, "out.pdf")
        var args = ["-sDEVICE=pdfwrite", "-dAutoRotatePages=/None"]
        if crop { args.append("-dEPSCrop") }
        try await run(gs, args, target, input, progress)
        try move(target, output)
    }

    private func toPdf(_ gs: String, _ step: ConversionStep, _ progress: ProgressHandler?) async throws -> [String] {
        guard let output = try step.output.allocate("pdf") else { return [] }
        try await Self.convertToPdf(gs, step.inputPath, output, crop: step.from == "eps", step.workDirectory, progress)
        return [output]
    }

    private func toPostScript(_ gs: String, _ step: ConversionStep, _ progress: ProgressHandler?) async throws -> [String] {
        guard let output = try step.output.allocate("ps") else { return [] }
        let target = FilePath.combine(try Self.newScratch(step.workDirectory), "out.ps")
        var args = ["-sDEVICE=ps2write"]
        if let pages = Self.selectedPages(step) { args.append("-sPageList=" + pages.map { String($0 + 1) }.joined(separator: ",")) }
        try await Self.run(gs, args, target, step.inputPath, progress)
        try Self.move(target, output)
        return [output]
    }

    /// EPS holds one page: a multi-page PDF becomes one EPS per page (`_p{n}` like PDF → PNG).
    private func toEps(_ gs: String, _ step: ConversionStep, _ progress: ProgressHandler?) async throws -> [String] {
        let scratch = try Self.newScratch(step.workDirectory)
        let pages = Self.selectedPages(step)
        var args = ["-sDEVICE=eps2write"]
        if let pages { args.append("-sPageList=" + pages.map { String($0 + 1) }.joined(separator: ",")) }
        // %d makes Ghostscript write one numbered file per page (1, 2, 3 … in output order).
        try await Self.run(gs, args, FilePath.combine(scratch, "page-%d.eps"), step.inputPath, progress)

        let files = Self.numberedFiles(scratch, "eps")
        if files.isEmpty { throw ConversionError("Ghostscript wrote no EPS file.") }
        var written: [String] = []
        for (file, index) in files {
            let pageNumber = pages != nil && index - 1 < pages!.count ? pages![index - 1] + 1 : index
            guard let path = try step.output.allocate("eps", suffix: files.count > 1 ? "_p\(pageNumber)" : nil) else { continue }
            try Self.move(file, path)
            written.append(path)
        }
        return written
    }

    /// EPS/PS → PNG with a transparent background where the drawing leaves the page empty, at the preset's render DPI,
    /// EPS cropped to its bounding box. A multi-page PS gives one PNG per page (`_p{n}`). The preset's image options
    /// (resize, grayscale, DPI, metadata) apply as for any other PNG.
    private func toPng(_ gs: String, _ step: ConversionStep, _ progress: ProgressHandler?) async throws -> [String] {
        let scratch = try Self.newScratch(step.workDirectory)
        let dpi = min(max(step.preset.pdf.renderDpi, 36), 1200)
        var args = ["-sDEVICE=pngalpha", "-r\(dpi)", "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4"]
        if step.from == "eps" { args.append("-dEPSCrop") }
        try await Self.run(gs, args, FilePath.combine(scratch, "page-%d.png"), step.inputPath, progress)

        let files = Self.numberedFiles(scratch, "png").map(\.path)
        if files.isEmpty { throw ConversionError("Ghostscript wrote no PNG file.") }
        let (format, ext) = ImageEncoder.outputFormat("png", step.preset.image)
        var written: [String] = []
        for (i, file) in files.enumerated() {
            guard let path = try step.output.allocate(ext, suffix: files.count > 1 ? "_p\(i + 1)" : nil) else { continue }
            let image = try ImageEncoder.applyOptions(try ImageReader.read(file, format: "png", preset: step.preset)[0], step.preset.image, targetFormat: "png")
            try ImageEncoder.save([image], to: path, format: format)
            written.append(path)
        }
        return written
    }

    /// "page-<n>.<ext>" files of a scratch folder, in page order.
    private static func numberedFiles(_ folder: String, _ ext: String) -> [(path: String, index: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.compactMap { name -> (String, Int)? in
            guard name.hasPrefix("page-"), name.hasSuffix("." + ext), let index = Int(name.dropFirst(5).dropLast(ext.count + 1)) else { return nil }
            return (FilePath.combine(folder, name), index)
        }.sorted { $0.1 < $1.1 }
    }

    /// The preset's page range as zero-based pages, or nil for every page (also when the PDF can't be read).
    private static func selectedPages(_ step: ConversionStep) -> [Int]? {
        guard !step.preset.pdf.pageRange.allSatisfy(\.isWhitespace) else { return nil }
        // PDFKit can't open every PDF Ghostscript can: convert all pages rather than fail.
        guard let document = PDFDocument(url: URL(fileURLWithPath: step.inputPath)), !document.isLocked else { return nil }
        return PageRange.parse(step.preset.pdf.pageRange, pageCount: document.pageCount)
    }

    /// Runs Ghostscript in safe mode. Outputs go to an ASCII-named scratch folder first: in -sOutputFile a '%' is a
    /// page-number placeholder, so arbitrary user paths can't be passed there.
    private static func run(_ gs: String, _ deviceArgs: [String], _ outputFile: String, _ input: String, _ progress: ProgressHandler?) async throws {
        let args = ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET"] + deviceArgs + ["-sOutputFile=" + outputFile, "-f", FilePath.fullPath(input)]
        let estimate = ProgressEstimate.start(progress, typical: 2)
        defer { estimate.stop() }
        let result = try await ProcessRunner.run(gs, args, timeout: timeout, environment: cleanEnvironment)

        let produced = outputFile.contains("%")
            ? !((try? FileManager.default.contentsOfDirectory(atPath: FilePath.directoryName(outputFile)!)) ?? []).isEmpty
            : ((try? FileManager.default.attributesOfItem(atPath: outputFile)[.size] as? Int) ?? 0) > 0
        if result.exitCode != 0 || !produced {
            let detail = lastLines(result.standardError + "\n" + result.standardOutput)
            throw ConversionError("Ghostscript failed (exit \(result.exitCode)). \(detail)".trimmingCharacters(in: .whitespaces))
        }
    }

    private static func newScratch(_ workDirectory: String) throws -> String {
        let folder = FilePath.combine(workDirectory, "gs-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        try FileManager.default.createDirectoryIfNeeded(folder)
        return folder
    }

    /// File.Move(overwrite: true).
    private static func move(_ source: String, _ destination: String) throws {
        FileManager.default.removeIfPresent(destination)
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }

    /// The end of Ghostscript's messages: the actual error is at the bottom.
    private static func lastLines(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(6).joined(separator: " ")
    }
}
