import Foundation
import XCTest
@testable import FileToXEngineKit

final class DocumentTextPerformanceTests: XCTestCase {
    private func document(_ paragraph: HParagraph) -> HDocument {
        let document = HDocument(), section = HSection()
        section.blocks = [paragraph]; document.sections = [section]
        return document
    }

    func testTrimmingMatchesOriginalWhitespaceSemantics() {
        let values = ["", "ASCII", "A\nB", "한글 😀", "\t\r\n", " plain \t\n", "\u{A0}A\u{3000}",
                      "\u{200B}A\u{200B}", "A \u{301}", "A\r\n", "e\u{301}\u{2028}", "\u{85}A\u{85}"]
        for value in values {
            XCTAssertEqual(DocumentXML.trim(value), value.trimmingCharacters(in: .whitespacesAndNewlines), value)
            XCTAssertEqual(DocumentXML.trimEnd(value), String(value.reversed().drop(while: { $0.isWhitespace }).reversed()), value)
            let p = DocumentFixtures.p(value)
            let expected = DocumentXML.trim(value).isEmpty ? "\n" : DocumentXML.trimEnd(value) + "\n"
            XCTAssertEqual(PlainTextWriter.write(document(p)), expected, value)
        }
    }

    func testMarkdownEscapesCharactersIncludingCombiningMarks() {
        for value in ["plain 한글 😀 e\u{301}", "\\`*_[]<>~^|=", "<\u{338}&\u{301}*\u{301}_\u{301}", "A🦊[B]e\u{301}"] {
            let expected = value.map { "\\`*_[]<>~^|=".contains($0) ? "\\\($0)" : String($0) }.joined() + "\n"
            XCTAssertEqual(MarkdownWriter.write(document(DocumentFixtures.p(value))) { _ in nil }, expected, value)
        }
    }

    func testMarkdownLineBreaksInHeadingsQuotesAndLists() {
        for hasBreak in [false, true] {
            let p = DocumentFixtures.p("first")
            if hasBreak { p.inlines += [HLineBreak(), HText("second")] }
            p.headingLevel = 1
            XCTAssertEqual(MarkdownWriter.write(document(p)) { _ in nil }, hasBreak ? "# first second\n" : "# first\n")
            p.headingLevel = 0; p.format.left = 2000
            XCTAssertEqual(MarkdownWriter.write(document(p)) { _ in nil }, hasBreak ? "> first\\\n> second\n" : "> first\n")
            p.format.left = nil
            let numbering = HNumbering(); numbering.levels = [HNumberingLevel("DIGIT", "^1.", 3, false)]
            p.list = HListRef(numbering, 0, true)
            XCTAssertEqual(MarkdownWriter.write(document(p)) { _ in nil }, hasBreak ? "3. first\\\n   second\n" : "3. first\n")
        }
    }

    func testHwpxEscapingMatchesLiteralReplacementAndFiltering() {
        for text in ["", "Plain 한글 😀 e\u{301}\t\n\r", "&<>'\"", "<\u{338}&\u{301}", "\u{0}\u{B}\u{FFFE}\u{FFFF}valid"] {
            var expected = String(String.UnicodeScalarView(text.unicodeScalars.filter {
                $0 == "\t" || $0 == "\n" || $0 == "\r" || ($0.value >= 0x20 && $0.value != 0xFFFE && $0.value != 0xFFFF)
            }))
            for (from, to) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&apos;")] {
                expected = expected.replacingOccurrences(of: from, with: to, options: .literal)
            }
            XCTAssertEqual(HwpxWriter.escape(text), expected, text)
        }
    }

    func testXmlTextFastPathStillValidatesEscapesAndNormalizesNewlines() throws {
        for (text, expected) in [("Plain 한글 😀 e\u{301}\t", "Plain 한글 😀 e\u{301}\t"),
                                 ("<&>\u{338}", "&lt;&amp;&gt;\u{338}"), ("a\r\nb\rc\nd", "a\nb\nc\nd")] {
            XCTAssertEqual(try XElement("p", text).toString(), "<p>\(expected)</p>")
        }
        for text in ["plain\u{1}", "&\u{1}", "plain\u{FFFE}", "\r\u{FFFF}"] {
            XCTAssertThrowsError(try XElement("p", text).toString(), text)
        }
    }
}
