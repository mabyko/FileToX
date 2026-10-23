// Port of Filee.Engines/Vector/VectorConverter.cs: built-in vector graphics: SVG/SVGZ → PDF (vector) and → raster
// images, SVG ↔ SVGZ, and Illustrator files → PDF. Other vector formats reach PNG, JPG, … through PDF.

import Foundation

/// SVG, SVGZ and AI conversions that need no external program.
final class VectorConverter: Converter {
    let id = "vector"
    let displayName = "Vector graphics (built-in)"
    let maxParallelism = 0

    let edges: [ConversionEdge] = [
        ConversionEdge("svg", "pdf"),
        ConversionEdge("svgz", "pdf"),
        ConversionEdge("svg", "svgz"),
        ConversionEdge("svgz", "svg"),
    ] + ImageEncoder.writable.flatMap { [ConversionEdge("svg", $0), ConversionEdge("svgz", $0)] }
        // Illustrator files are PDF inside (or PostScript, see convertIllustrator).
        + [ConversionEdge("ai", "pdf")]

    func status() -> EngineStatus { .available(version: "\(EngineVersions.builtIn) · \(EngineVersions.system("CoreSVG"))") }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        let written: [String]
        switch (step.from, step.to) {
        case ("ai", "pdf"): written = try await convertIllustrator(step, progress)
        case ("svg", "svgz"): written = try compress(step)
        case ("svgz", "svg"): written = try decompress(step)
        case (_, "pdf"): written = try toPdf(step)
        default: written = try toRaster(step, progress)
        }
        progress?(1)
        return written
    }

    private func toPdf(_ step: ConversionStep) throws -> [String] {
        let drawing = try SvgRenderer.load(step.inputPath)
        try Task.checkCancellation()
        guard let output = try step.output.allocate("pdf") else { return [] }
        try SvgRenderer.writePdf(drawing, output, title: FormatRegistry.nameWithoutExtension(step.inputPath), pdfA: step.preset.document.pdfA)
        return [output]
    }

    private func toRaster(_ step: ConversionStep, _ progress: ProgressHandler?) throws -> [String] {
        let drawing = try SvgRenderer.load(step.inputPath)
        progress?(0.2)
        let scale = SvgRenderer.rasterScale(drawing.bounds, step.preset.image, step.preset.pdf)
        var image = try SvgRenderer.rasterize(drawing, scale: scale)
        try Task.checkCancellation()
        progress?(0.6)

        // The drawing was rendered at its final size, so the preset's resize must not scale the bitmap again.
        var options = step.preset.image
        options.resize = .none
        image = try ImageEncoder.applyOptions(image, options, targetFormat: step.to)
        return try ImageEncoder.write([image], targetFormat: step.to, output: step.output, options: options)
    }

    private func compress(_ step: ConversionStep) throws -> [String] {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: step.inputPath))
        if !SvgRenderer.isGzip(bytes) { try Self.requireSvgText(bytes) }
        guard let output = try step.output.allocate("svgz") else { return [] }
        // A gzipped file named .svg is already SVGZ.
        try (SvgRenderer.isGzip(bytes) ? bytes : try Deflate.deflate(bytes, level: 9, windowBits: 31)).write(to: URL(fileURLWithPath: output))
        return [output]
    }

    private func decompress(_ step: ConversionStep) throws -> [String] {
        let bytes = try SvgRenderer.readSvgBytes(step.inputPath)
        try Self.requireSvgText(bytes)
        guard let output = try step.output.allocate("svg") else { return [] }
        try bytes.write(to: URL(fileURLWithPath: output))
        return [output]
    }

    /// Guards SVG ↔ SVGZ, which never parse the drawing, against renamed non-SVG files.
    private static func requireSvgText(_ bytes: Data) throws {
        let head = String(decoding: bytes.prefix(4096), as: UTF8.self)
        if head.range(of: "<svg", options: .caseInsensitive) == nil {
            throw ConversionError("The file is not an SVG drawing (no <svg> element).")
        }
    }

    // ───────────────────────── Illustrator ─────────────────────────

    /// Illustrator 9 and later save a complete PDF inside the .ai file ("Create PDF compatible file", on by default),
    /// so the file is copied as a PDF after checking its header. Files saved without it (and Illustrator 8 and older)
    /// are PostScript, which needs Ghostscript.
    private func convertIllustrator(_ step: ConversionStep, _ progress: ProgressHandler?) async throws -> [String] {
        let kind = try Self.illustratorKind(step.inputPath)
        if kind == .unknown { throw ConversionError("The file is not an Adobe Illustrator document (neither PDF nor PostScript inside).") }

        guard let output = try step.output.allocate("pdf") else { return [] }
        if kind == .pdf {
            FileManager.default.removeIfPresent(output)
            try FileManager.default.copyItem(atPath: step.inputPath, toPath: output)
            return [output]
        }
        guard let gs = GhostscriptConverter.locate() else {
            throw ConversionError("This Illustrator file was saved without PDF compatibility, so it is PostScript. " +
                                  "Install Ghostscript in Settings → Engines to convert it, or save it in Illustrator with \"Create PDF compatible file\".")
        }
        try await GhostscriptConverter.convertToPdf(gs, step.inputPath, output, crop: true, step.workDirectory, progress)
        return [output]
    }

    enum AiKind { case unknown, pdf, postScript }

    /// Looks at the header: PDF-compatible files have "%PDF-" in the first 1 KB (where a PDF reader accepts it);
    /// PostScript-based ones start with "%!PS" or the binary header of a DOS EPS file (C5 D0 D3 C6).
    static func illustratorKind(_ path: String) throws -> AiKind {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ConversionError("\(FilePath.fileName(path)) can't be read.") }
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 1024)) ?? Data()
        if head.range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        if head.starts(with: Data("%!PS".utf8)) || head.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) { return .postScript }
        return .unknown
    }
}
