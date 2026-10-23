// Port of Filee.Engines/Ebooks/CalibreConverter.cs.
import Foundation

public final class CalibreConverter: Converter {
    static let inputs = ["lit", "lrf", "chm", "pdb", "pml", "rb", "snb", "tcr", "oeb"]
    static let outputs = ["mobi", "azw3", "lit", "lrf", "pdb", "pml", "rb", "snb", "tcr"]
    private var executable: String?
    public let id = "calibre"
    public let displayName = "Calibre"
    public let maxParallelism = 2
    public let edges = inputs.map { ConversionEdge($0, "epub", 20) } + outputs.map { ConversionEdge("epub", $0, 20) }
    public init() {}

    public func status() -> EngineStatus {
        executable = Self.locate()
        return executable.map { .available(detail: $0, version: EngineEnvironment.usesBundledCopy("calibre") ? EngineVersions.component("calibre") : nil) } ?? .unavailable("engine.reason.not_installed")
    }
    public func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        guard let executable = executable ?? Self.locate() else { throw ConversionError("Calibre is not installed.") }
        let work = try EbookFiles.newFolder(step.workDirectory, "calibre")
        var input = step.inputPath
        if !input.lowercased().hasSuffix(".opf") {
            input = FilePath.combine(work, "input." + (step.from == "oeb" ? "zip" : step.from))
            try FileManager.default.copyItem(atPath: step.inputPath, toPath: input)
        }
        let temp = FilePath.combine(work, "output." + step.to)
        var environment = ["CALIBRE_OVERRIDE_LANG": "en", "PYTHONIOENCODING": "utf-8"]
        for (key, name) in [("CALIBRE_CONFIG_DIRECTORY", "config"), ("CALIBRE_CACHE_DIRECTORY", "cache"), ("CALIBRE_TEMP_DIR", "temp")] {
            let folder = FilePath.combine(work, name)
            try FileManager.default.createDirectoryIfNeeded(folder); environment[key] = folder
        }
        progress?(0.02)
        let result = try await ProcessRunner.run(executable, [input, temp], timeout: 600, workingDirectory: work, environment: environment, onOutput: { Self.reportProgress($0, progress) })
        guard result.exitCode == 0, FileManager.default.fileExists(temp) else {
            let output = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.standardOutput : result.standardError
            throw ConversionError("Calibre failed (exit \(result.exitCode)). \(Self.lastLines(output))")
        }
        guard let output = try step.output.allocate(step.to) else { return [] }
        try EbookFiles.replace(temp, output)
        progress?(1)
        return [output]
    }
    static func reportProgress(_ line: String, _ progress: ProgressHandler?) {
        if let progress, let match = EbookRegex.matches(#"^\s*(\d{1,3})%\s"#, line).first, let percent = Int(EbookRegex.group(match, line, 1)) {
            progress(Double(min(100, max(0, percent))) / 100 * 0.95)
        }
    }
    static func lastLines(_ output: String) -> String {
        output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.suffix(3).joined(separator: " ")
    }
    static func locate() -> String? {
        EngineEnvironment.ownProgram("calibre", "ebook-convert.exe") ?? EngineEnvironment.bundledProgram("calibre", "ebook-convert.exe") ?? EngineEnvironment.systemProgram("calibre", "ebook-convert.exe")
    }
}
