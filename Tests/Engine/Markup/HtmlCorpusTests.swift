// Comparison with Filee: dumps every HTML / XHTML file of $FTX_HTML_CORPUS into $FTX_HTML_CORPUS_OUT in the canonical
// format the Filee harness prints (`htmlparse`, or `htmlread` with FTX_HTML_CORPUS_MODE=read), so both readers'
// results can be diffed. Skipped without the variables.

import Foundation
import XCTest
@testable import FileToXEngineKit

final class HtmlCorpusTests: XCTestCase {
    func testDumpCorpus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let corpus = environment["FTX_HTML_CORPUS"], let output = environment["FTX_HTML_CORPUS_OUT"] else {
            throw XCTSkip("set FTX_HTML_CORPUS and FTX_HTML_CORPUS_OUT to dump a corpus")
        }
        try FileManager.default.createDirectoryIfNeeded(output)
        for name in try FileManager.default.contentsOfDirectory(atPath: corpus).sorted() where name.hasSuffix(".html") || name.hasSuffix(".xhtml") {
            if environment["FTX_HTML_CORPUS_MODE"] == "read" {
                let document = try HtmlReader.read(FilePath.combine(corpus, name), FilePath.combine(output, "media"))
                try MarkupTestSupport.dump(document).write(toFile: FilePath.combine(output, name + ".txt"), atomically: true, encoding: .utf8)
                continue
            }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: FilePath.combine(corpus, name)))
            let options = HtmlReadOptions(baseFolder: corpus, mediaFolder: FilePath.combine(output, "media"))
            let content = try HtmlReader.parse(HtmlReader.decode(bytes), options, name.hasSuffix(".xhtml"))
            let dump = "TITLE \(MarkupTestSupport.quote(content.title))\nLANG \(MarkupTestSupport.quote(content.language))\n"
                + MarkupTestSupport.dump(blocks: content.blocks)
            try dump.write(toFile: FilePath.combine(output, name + ".txt"), atomically: true, encoding: .utf8)
        }
    }
}
