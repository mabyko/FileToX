// Port of Filee.Engines/Fonts/FontConverter.cs.
import Foundation

public final class FontConverter: Converter {
    public let id = "font"
    public let displayName = "Fonts (built-in)"
    public let maxParallelism = 0
    public let edges = FontFile.formats.flatMap { source in FontFile.formats.filter { $0 != source }.map { ConversionEdge(source, $0) } }
    public init() {}
    public func status() -> EngineStatus { .available(detail: "TTF, OTF, WOFF, WOFF2, EOT", version: EngineVersions.builtIn) }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        try Task.checkCancellation()
        let font = try FontFile.load(Data(contentsOf: URL(fileURLWithPath: step.inputPath)))
        progress?(0.2)
        var outlines: ProgressHandler?
        if let parent = progress { outlines = { value in parent(0.2 + 0.6 * value) } }
        let data = try FontFile.save(font, step.to, outlines)
        progress?(0.9)
        guard let output = try step.output.allocate(step.to) else { return [] }
        try data.write(to: URL(fileURLWithPath: output))
        progress?(1)
        return [output]
    }
}
