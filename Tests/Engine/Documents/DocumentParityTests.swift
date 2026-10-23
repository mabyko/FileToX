import Foundation
import XCTest

@testable import FileToXEngineKit

final class DocumentParityTests: DocumentTestCase {
    // Leaves comparable inputs/outputs only when FILETOX_DOCUMENT_FIXTURE_OUTPUT is set.
    func testBuildBaselineComparisonFixtures() async throws {
        let input = try write("안녕하세요\n\n두 번째 줄 <태그> & 기호 😀\n", "한글 문서.txt")
        let rich = try DocumentFixtures.richDocx(folder)
        let slides = try DocumentFixtures.slides(path("slides.pptx"))
        var cases: [[String: String]] = []
        for (file, from) in [(input, "txt"), (rich, "docx"), (slides, "pptx")] {
            for to in ["hwpx", "docx"] where from != to {
                let engine: Converter = to == "hwpx" ? HwpxConverter() : DocxWriterConverter()
                let name = "swift-\(from).\(to)"
                let out = try await convert(engine, file, from, to, name)
                if to == "hwpx" { try HwpxAssert.validPackage(out) } else { try DocxAssert.validPackage(out) }
                cases.append(["input": file, "from": from, "to": to, "swift": out])
            }
        }
        let linkDoc = HDocument()
        let linkSection = HSection()
        let linkParagraph = HParagraph()
        for target in [
            "HTTPS://EXAMPLE.COM:443/a/../?q=한글", "http://example.com", "https://example.com/a b",
            "mailto:user@example.com", "file:///tmp/a b",
        ] {
            let link = HLink(target)
            link.content = [HText(target)]
            linkParagraph.inlines.append(link)
        }
        linkSection.blocks = [linkParagraph]
        linkDoc.sections = [linkSection]
        let linkInput = path("links.hwpx")
        try HwpxWriter.write(linkDoc, linkInput)
        let linkOutput = try await convert(DocxWriterConverter(), linkInput, "hwpx", "docx", "swift-links.docx")
        cases.append(["input": linkInput, "from": "hwpx", "to": "docx", "swift": linkOutput])
        let hwpx = path("swift-docx.hwpx")
        let docx = try await convert(DocxWriterConverter(), hwpx, "hwpx", "docx", "swift-hwpx.docx")
        try DocxAssert.validPackage(docx)
        cases.append(["input": hwpx, "from": "hwpx", "to": "docx", "swift": docx])
        for to in ["txt", "md", "html"] {
            let out = try await convert(UnhwpConverter(), hwpx, "hwpx", to, "swift-unhwp." + to)
            cases.append(["input": hwpx, "from": "hwpx", "to": to, "swift": out])
        }
        if RhwpConverter.locate() != nil {
            let hwp = try await convert(RhwpConverter(), hwpx, "hwpx", "hwp", "swift-rhwp.hwp")
            let pdf = try await convert(RhwpConverter(), hwp, "hwp", "pdf", "swift-rhwp.pdf")
            cases.append(["input": hwpx, "from": "hwpx", "to": "hwp", "swift": hwp])
            cases.append(["input": hwp, "from": "hwp", "to": "pdf", "swift": pdf])
            for to in ["txt", "md", "html"] {
                let out = try await convert(UnhwpConverter(), hwp, "hwp", to, "swift-hwp." + to)
                cases.append(["input": hwp, "from": "hwp", "to": to, "swift": out])
            }
        }
        try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: path("parity-cases.json")))
    }
}
