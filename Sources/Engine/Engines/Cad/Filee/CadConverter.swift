// Port of Filee.Engines/Cad/CadConverter.cs: DWG / DXF conversion without AutoCAD. The ACadSharp port reads DWG R13–
// 2018+ and DXF (ASCII and binary) and writes DXF and DWG; the drawing is rendered with CoreGraphics to PDF (vector),
// SVG and raster images.

import Foundation

/// DWG ↔ DXF and DWG / DXF → PDF, SVG, PNG, JPG, WEBP, TIFF, BMP, GIF, ICO, AVIF …
///
/// Rendering draws model space as seen from the top (the active layout when model space is empty), fitted to the
/// page: PDF on an A3 sheet (A4 / Letter when the preset says so), SVG and images with the drawing's aspect ratio on
/// a white background.
final class CadConverter: Converter {
    private static let sources = ["dwg", "dxf"]

    var id: String { "cad" }
    var displayName: String { "CAD (built-in)" }

    /// A loaded drawing takes several times its file size in memory (a 55 MB DXF peaks around 800 MB), so only a few
    /// are converted at once.
    var maxParallelism: Int { min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 1), 4) }

    let edges: [ConversionEdge] = [ConversionEdge("dwg", "dxf"), ConversionEdge("dxf", "dwg")]
        + sources.flatMap { source in (["pdf", "svg"] + ImageEncoder.writable).map { ConversionEdge(source, $0) } }

    func status() -> EngineStatus {
        .available(detail: "ACadSharp: DWG R13–2018+, DXF", version: EngineVersions.builtIn + " · ACadSharp 3.8.0")
    }

    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        progress?(0.05)
        let document = try CadFile.read(step.inputPath, step.from)
        try Task.checkCancellation()
        progress?(0.4)

        if step.to == "dxf" || step.to == "dwg" {
            guard let path = try step.output.allocate(step.to) else { return [] }
            try CadFile.write(document, path, step.to)
            progress?(1)
            return [path]
        }

        let scene = try CadSceneBuilder.build(document)
        if scene.items.isEmpty {
            throw ConversionError(scene.skipped.isEmpty
                ? "The drawing has nothing visible to draw: model space and the layout are empty, or every entity is on a layer that is off, frozen or not plotted."
                : "The drawing only contains objects Filee cannot draw (\(scene.skippedTypes.joined(separator: ", "))).")
        }
        try Task.checkCancellation()
        progress?(0.7)

        guard let output = try step.output.allocate(step.to) else { return [] }
        switch step.to {
        case "pdf":
            try CadRenderer.pdf(scene, step.preset.pdf, FilePath.fileNameWithoutExtension(step.inputPath)).write(to: URL(fileURLWithPath: output))
        case "svg":
            try CadRenderer.svg(scene).write(to: URL(fileURLWithPath: output))
        default:
            try writeImage(scene, step, output)
        }
        progress?(1)
        return [output]
    }

    /// Renders at the preset's render resolution (PDF → image uses the same setting; 150 dpi by default, for an
    /// A3-sized page that is about 2500 px on the long edge), then applies the image options like other image
    /// conversions do (resize, grayscale, quality, DPI).
    private func writeImage(_ scene: CadScene, _ step: ConversionStep, _ output: String) throws {
        let dpi = min(max(step.preset.pdf.renderDpi, 36), 1200)
        let image = try CadRenderer.renderBitmap(scene, Double(dpi))
        let frame = try ImageEncoder.applyOptions(ImageFrame(image: image, dpi: (Double(dpi), Double(dpi))), step.preset.image, targetFormat: step.to)
        try ImageEncoder.save([frame], to: output, format: step.to)
    }
}
