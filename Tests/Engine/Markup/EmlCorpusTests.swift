// Runs the e-mail engine over a folder of sample messages for the comparison with the C# helper: every
// $FTX_EML_CORPUS/src/*.eml is converted to html, txt and zip in $FTX_EML_CORPUS/swift-<target>/, with the state of each
// file in swift-<target>.jsonl (the format of the baseline driver). Skipped when the variable is not set.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class EmlCorpusTests: XCTestCase {
    func testConvertCorpus() async throws {
        guard let root = ProcessInfo.processInfo.environment["FTX_EML_CORPUS"] else { throw XCTSkip("FTX_EML_CORPUS is not set") }
        let fm = FileManager.default
        let sources = try fm.contentsOfDirectory(atPath: FilePath.combine(root, "src")).filter { $0.hasSuffix(".eml") }.sorted()
        for target in ["html", "txt", "zip"] {
            let folder = FilePath.combine(root, "swift-" + target)
            fm.removeIfPresent(folder)
            try fm.createDirectoryIfNeeded(folder)
            var log = ""
            for name in sources {
                let input = FilePath.combine(folder, name)
                try fm.copyItem(atPath: FilePath.combine(root, "src", name), toPath: input)
                var entry: [String: Any] = ["source": name]
                do {
                    let step = ConversionStep(inputPath: input, from: "eml", to: target, preset: Preset(), output: SiblingOutput(input), workDirectory: folder)
                    entry["outputs"] = try await EmlConverter().convert(step, progress: nil)
                    entry["state"] = "done"
                } catch {
                    entry["state"] = "failed"
                    entry["error"] = error.localizedDescription
                }
                log += String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self) + "\n"
            }
            try Data(log.utf8).write(to: URL(fileURLWithPath: FilePath.combine(root, "swift-\(target).jsonl")))
        }
    }
}

/// `<input folder>/<input name>.<ext>`.
private final class SiblingOutput: OutputAllocator {
    let input: String
    init(_ input: String) { self.input = input }

    func allocate(_ extension: String, suffix: String?) throws -> String? {
        FilePath.combine(FilePath.directoryName(input) ?? "", FilePath.fileNameWithoutExtension(input) + (suffix ?? "") + "." + `extension`)
    }
}
