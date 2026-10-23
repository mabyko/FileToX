import Foundation
import XCTest
@testable import FileToXEngineKit

final class CoreTempDir {
    let path = FilePath.combine(NSTemporaryDirectory(), "ftx-core-" + UUID().uuidString)
    init() { try! FileManager.default.createDirectoryIfNeeded(path) }
    deinit { FileManager.default.removeIfPresent(path) }
    @discardableResult func file(_ name: String, _ text: String = "x") throws -> String { let p = FilePath.combine(path, name); try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(p)!); try Data(text.utf8).write(to: URL(fileURLWithPath: p)); return p }
    func read(_ name: String) throws -> String { try String(contentsOfFile: FilePath.combine(path, name), encoding: .utf8) }
    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: path).sorted() }
    func leftovers() -> [String] { (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? []).filter { FilePath.fileName($0).hasPrefix(OutputCommit.stagingPrefix) } }
}
final class CoreFakeConverter: Converter {
    let id: String, displayName: String, edges: [ConversionEdge]
    var maxParallelism = 0, available = true, outputsPerInput = 1, shouldThrow = false
    var script: ((ConversionStep) async throws -> [String])?
    init(_ id: String = "fake", _ edges: ConversionEdge...) { self.id = id; displayName = id; self.edges = edges }
    init(edges: [ConversionEdge], script: @escaping (ConversionStep) async throws -> [String]) { id = "scripted"; displayName = "scripted"; self.edges = edges; self.script = script }
    func status() -> EngineStatus { available ? .available() : .unavailable("engine.reason.not_installed") }
    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        if let script { return try await script(step) }
        if shouldThrow { throw ConversionError("boom") }
        var outputs: [String] = []
        for i in 1...outputsPerInput {
            try Task.checkCancellation()
            if let output = try step.output.allocate(step.to, suffix: outputsPerInput > 1 ? "_p\(i)" : nil) { try Data("converted".utf8).write(to: URL(fileURLWithPath: output)); outputs.append(output) }
        }
        progress?(1); return outputs
    }
}
final class CoreFakeMerger: PdfMerger, TiffMerger {
    var inputs: [String] = []
    func merge(_ inputPaths: [String], into outputPath: String) async throws { inputs = inputPaths; try Data(inputPaths.map(FilePath.fileName).joined(separator: "|").utf8).write(to: URL(fileURLWithPath: outputPath)) }
    func merge(_ inputPaths: [String], into outputPath: String, options: ImageOptions) async throws { try await merge(inputPaths, into: outputPath) }
}
final class CoreFakeCombiner: FileCombiner {
    var inputs: [String] = [], shouldThrow = false
    func canCombine(into format: String) -> Bool { true }
    func combine(_ inputPaths: [String], into outputPath: String, format: String, preset: Preset, workDirectory: String, progress: ProgressHandler?) async throws { if shouldThrow { throw ConversionError("boom") }; inputs = inputPaths; try Data("archive".utf8).write(to: URL(fileURLWithPath: outputPath)) }
}
func corePreset(_ format: String, _ change: (inout Preset) -> Void = { _ in }) -> Preset { var p = Preset(); p.targetFormat = format; change(&p); return p }
func coreRun(_ queue: JobQueue, _ paths: [String], _ preset: Preset) async -> ConversionJob { let j = ConversionJob(paths, preset, "Test"); await queue.run(j); return j }
