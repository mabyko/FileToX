// Ports of Filee's PandocMarkupTests and PandocStagingTests: reStructuredText and LaTeX through Pandoc (to and from
// Markdown, HTML, DOCX, EPUB, and to HWPX through Pandoc's AST and the built-in HWPX writer), and the staging of the
// media Pandoc extracts ("<name>_files"). Skipped when no Pandoc copy is found ($FILETOX_PANDOC, the development
// copy of the FileToX checkout, or one on the Mac).

import Foundation
import XCTest
@testable import FileToXEngineKit

/// Points the engines at a Pandoc copy for the duration of a test.
class PandocTestCase: XCTestCase {
    private var savedOwnCopies: [String: String] = [:]

    override func setUpWithError() throws {
        savedOwnCopies = EngineEnvironment.ownCopies
        guard let folder = MarkupTestSupport.pandocFolder() else { throw XCTSkip("Pandoc not installed") }
        EngineEnvironment.ownCopies = ["pandoc": folder]
    }

    override func tearDown() {
        EngineEnvironment.ownCopies = savedOwnCopies
        super.tearDown()
    }

    func write(_ name: String, _ text: String) throws -> String {
        let path = FilePath.combine(try MarkupTestSupport.newFolder(), name)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }
}

final class PandocMarkupTests: PandocTestCase {
    private static let rst = """
        Weekly notes
        ============

        Decided: **ship it** and *write docs*.

        - first item
        - second item

        Next steps
        ==========

        Two sections of the same level, so the first one stays a heading (a lone one would become the title).
        """

    private static let tex = """
        \\documentclass{article}
        \\begin{document}
        \\section{Results}
        The result is \\textbf{good} and \\emph{fast}.
        \\end{document}
        """

    private func hwpxText(_ path: String) throws -> String {
        let document = try HwpxReader.read(path, FilePath.combine(FilePath.directoryName(path)!, "readback"))
        return document.sections.map { HDocumentAssert.text($0.blocks) }.joined()
    }

    func testMarkupRoutes() throws {
        let converters = MarkupTestSupport.converters()
        let planner = ConverterCatalog(converters).createPlanner(["pandoc"])
        for (from, to) in [("rst", "docx"), ("rst", "md"), ("tex", "html"), ("tex", "epub"), ("md", "rst"), ("docx", "tex")] {
            XCTAssertEqual(planner.plan(from, to)?.steps.map(\.converter.id), ["pandoc"], "\(from) → \(to)")
        }
        XCTAssertFalse(try XCTUnwrap(converters.first { $0.id == "pandoc" }).edges.contains { $0.to == "pdf" })

        // The HWPX writer offers its Pandoc-based readers only when Pandoc is really there (not just assumed).
        XCTAssertNotNil(PandocConverter.locate())
        XCTAssertEqual(planner.plan("rst", "hwpx")?.steps.map(\.converter.id), ["hwpx-writer"])
        XCTAssertEqual(planner.plan("tex", "hwpx")?.steps.map(\.converter.id), ["hwpx-writer"])
    }

    func testRstToDocxMarkdownAndHwpx() async throws {
        let rst = try write("notes.rst", Self.rst)

        let docx = try DocxAssert.readBack(try await MarkupTestSupport.convert(rst, "docx"))
        let paragraphs = DocxAssert.paragraphs(docx.sections.flatMap(\.blocks))
        XCTAssertEqual(paragraphs.first { DocxAssert.textOf($0) == "Weekly notes" }?.headingLevel, 1)

        let md = try String(contentsOfFile: try await MarkupTestSupport.convert(rst, "md"), encoding: .utf8)
        XCTAssertTrue(md.contains("# Weekly notes"))
        XCTAssertTrue(md.contains("**ship it**"))

        let hwpx = try await MarkupTestSupport.convert(rst, "hwpx")
        try HwpxAssert.validPackage(hwpx)
        XCTAssertTrue(try hwpxText(hwpx).contains("first item"))
    }

    func testLatexToMarkdownEpubAndBack() async throws {
        let tex = try write("paper.tex", Self.tex)

        let md = try String(contentsOfFile: try await MarkupTestSupport.convert(tex, "md"), encoding: .utf8)
        XCTAssertTrue(md.contains("# Results"))
        XCTAssertTrue(md.contains("**good**"))

        let epub = try ZipReader(path: try await MarkupTestSupport.convert(tex, "epub"))
        XCTAssertEqual(try epub.string(named: "mimetype"), "application/epub+zip")

        let markdown = try write("draft.md", "# Title\n\nSome *text*.\n")
        let latex = try String(contentsOfFile: try await MarkupTestSupport.convert(markdown, "tex"), encoding: .utf8)
        XCTAssertTrue(latex.contains("\\begin{document}")) // standalone, ready to compile
        XCTAssertTrue(latex.contains("\\section{Title}"))

        let hwpx = try await MarkupTestSupport.convert(tex, "hwpx")
        try HwpxAssert.validPackage(hwpx)
        XCTAssertTrue(try hwpxText(hwpx).contains("The result is"))
    }
}

final class PandocStagingTests: PandocTestCase {
    /// A DOCX with one picture, in a folder of its own.
    private func docxWithPicture() async throws -> String {
        let folder = try MarkupTestSupport.newFolder()
        try MarkupTestSupport.png(160, 90).write(to: URL(fileURLWithPath: FilePath.combine(folder, "chart.png")))
        let md = FilePath.combine(folder, "doc.md")
        try Data("# Title\n\n![chart](chart.png)\n".utf8).write(to: URL(fileURLWithPath: md))
        let job = await MarkupTestSupport.run([md], MarkupTestSupport.preset("docx"))
        XCTAssertEqual(job.state, .completed, job.files.map { "\($0.errorKey ?? "") \($0.errorDetail ?? "")" }.joined())
        let docx = FilePath.combine(folder, "doc.docx")
        XCTAssertTrue(job.outputs.contains(docx))
        try FileManager.default.removeItem(atPath: md)
        try FileManager.default.removeItem(atPath: FilePath.combine(folder, "chart.png"))
        return docx
    }

    private func toMarkdown(_ docx: String, _ outFolder: String, _ conflict: ConflictPolicy) async -> ConversionJob {
        await MarkupTestSupport.run([docx], MarkupTestSupport.preset("md") {
            $0.output.location = .customFolder
            $0.output.customFolder = outFolder
            $0.output.conflict = conflict
        })
    }

    private func leftovers(_ folder: String) -> [String] {
        (FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? [])
            .filter { FilePath.fileName($0).hasPrefix(OutputCommit.stagingPrefix) }
    }

    func testMediaIsStagedCommittedNextToTheOutputAndLinkedRelatively() async throws {
        let docx = try await docxWithPicture()
        let outFolder = try MarkupTestSupport.newFolder()

        let job = await toMarkdown(docx, outFolder, .rename)

        XCTAssertEqual(job.state, .completed, job.files.map { "\($0.errorKey ?? "") \($0.errorDetail ?? "")" }.joined())
        XCTAssertEqual(job.outputs, [FilePath.combine(outFolder, "doc.md")])
        let markdown = try String(contentsOfFile: FilePath.combine(outFolder, "doc.md"), encoding: .utf8)
        let link = try NSRegularExpression(pattern: #"src="(doc_files/[^"]+)"|\]\((doc_files/[^)]+)\)"#)
        let match = try XCTUnwrap(link.firstMatch(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)), "no relative media link")
        let target = (1...2).compactMap { Range(match.range(at: $0), in: markdown).map { String(markdown[$0]) } }.joined()
        XCTAssertTrue(FileManager.default.fileExists(FilePath.combine(outFolder, target)))
        // Nothing went next to the source, and no staging folder is left.
        XCTAssertFalse(FileManager.default.directoryExists(FilePath.combine(FilePath.directoryName(docx)!, "doc_files")))
        XCTAssertEqual(leftovers(outFolder), [])
        XCTAssertEqual(leftovers(FilePath.directoryName(docx)!), [])
    }

    func testAMediaFolderInTheWayIsNotTouchedAndNothingIsPublished() async throws {
        let docx = try await docxWithPicture()
        let outFolder = try MarkupTestSupport.newFolder()
        let theirs = FilePath.combine(outFolder, "doc_files", "media")
        try FileManager.default.createDirectoryIfNeeded(theirs)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: FilePath.combine(theirs, "rId9.png")))

        let job = await toMarkdown(docx, outFolder, .rename)

        XCTAssertEqual(job.files[0].state, .failed)
        XCTAssertEqual(job.files[0].errorKey, "error.output_exists")
        XCTAssertFalse(FileManager.default.fileExists(FilePath.combine(outFolder, "doc.md")))
        XCTAssertEqual(try String(contentsOfFile: FilePath.combine(theirs, "rId9.png"), encoding: .utf8), "mine")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: theirs), ["rId9.png"])
        XCTAssertEqual(leftovers(outFolder), [])
    }

    func testOverwritingMergesTheMediaFolderAndKeepsUnrelatedFiles() async throws {
        let docx = try await docxWithPicture()
        let outFolder = try MarkupTestSupport.newFolder()
        let media = FilePath.combine(outFolder, "doc_files")
        try FileManager.default.createDirectoryIfNeeded(media)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: FilePath.combine(media, "keep.txt")))

        let job = await toMarkdown(docx, outFolder, .overwrite)

        XCTAssertEqual(job.state, .completed, job.files.map { "\($0.errorKey ?? "") \($0.errorDetail ?? "")" }.joined())
        XCTAssertEqual(try String(contentsOfFile: FilePath.combine(media, "keep.txt"), encoding: .utf8), "mine")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: FilePath.combine(media, "media")).isEmpty)
        XCTAssertEqual(leftovers(outFolder), [])
    }
}
