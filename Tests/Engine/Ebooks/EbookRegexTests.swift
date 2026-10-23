import Foundation
import XCTest
@testable import FileToXEngineKit

final class EbookRegexTests: EbookTestCase {
    func testReplacementUsesOriginalUTF16OffsetsAndInputOrder() {
        let text = "😀 [한글] e\u{301} [🦊] tail"
        var values: [String] = []
        let output = EbookRegex.replace(#"\[([^]]+)\]"#, text) { match in
            values.append(EbookRegex.group(match, text, 1))
            return "\(values.count):\(values.last!)"
        }
        XCTAssertEqual(values, ["한글", "🦊"])
        XCTAssertEqual(output, "😀 1:한글 e\u{301} 2:🦊 tail")
        XCTAssertEqual(EbookRegex.replace("missing", text) { _ in XCTFail("no match"); return "" }, text)
        XCTAssertEqual(EbookRegex.replace("^|$", "😀") { _ in "!" }, "!😀!")
        XCTAssertEqual(EbookRegex.replace("a", "aaa") { _ in "" }, "")
    }

    func testThrowingReplacementStopsInInputOrder() {
        enum Failure: Error { case expected }
        var positions: [Int] = []
        XCTAssertThrowsError(try EbookRegex.replace(".", "abc") { match in
            positions.append(match.range.location)
            if positions.count == 2 { throw Failure.expected }
            return "longer"
        })
        XCTAssertEqual(positions, [0, 1])
    }

    func testFb2CleaningPreservesUnicodeAndDropsInvalidScalars() throws {
        let document = HDocument(), section = HSection(), paragraph = HParagraph()
        paragraph.inlines = [HText("Plain 한글 😀 e\u{301}"), HText("\u{0}\u{B}\u{FFFE}\u{FFFF}<&>")]
        section.blocks = [paragraph]; document.sections = [section]
        let output = path("unicode.fb2")
        try Fb2Writer.write(Book(document, BookMetadata()), output, "unicode.epub", folder)
        let xml = try XDocument.load(output)
        let body = try XCTUnwrap(xml.root.elements().first { $0.name.localName == "body" })
        XCTAssertEqual(body.value, "Plain 한글 😀 e\u{301}<&>")
    }
}
