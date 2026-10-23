import Foundation
import Darwin

enum FakeEngines {
    static func create() -> [Converter] { [NoisyConverter()] }
    private final class NoisyConverter: Converter {
        let id = "fake", displayName = "Fake", maxParallelism = 0
        let edges = [ConversionEdge("txt", "md"), ConversionEdge("txt", "txt")]
        func status() -> EngineStatus { .available(version: "1") }
        func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
            let noise = Array("native-noise-without-newline".utf8)
            _ = noise.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!, $0.count) }
            print("managed-noise", terminator: "")
            guard let output = try step.output.allocate(step.to) else { return [] }
            try Data(("converted " + FilePath.fileName(step.inputPath)).utf8).write(to: URL(fileURLWithPath: output))
            progress?(1); return [output]
        }
    }
}
