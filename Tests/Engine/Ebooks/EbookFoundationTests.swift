import Foundation
import XCTest
import PDFKit
@testable import FileToXEngineKit

class EbookTestCase: XCTestCase {
    var folder: String!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ftx-ebooks-\(UUID().uuidString)").path
        try FileManager.default.createDirectoryIfNeeded(folder)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: folder) }
    func path(_ name: String) -> String { FilePath.combine(folder, name) }
    func save(_ name: String, _ bytes: Data) throws -> String { let p = path(name); try bytes.write(to: URL(fileURLWithPath: p)); return p }
    func convert(_ input: String, _ from: String, _ to: String, _ preset: Preset = Preset(), _ engine: Converter = EbookConverter()) async throws -> String {
        let allocator = EbookTestOutput(path("output-\(UUID().uuidString)"))
        let outputs = try await engine.convert(ConversionStep(inputPath: input, from: from, to: to, preset: preset, output: allocator, workDirectory: folder), progress: nil)
        return try XCTUnwrap(outputs.first)
    }
    func inlines(_ document: HDocument) -> [HInline] { document.sections.flatMap { HDocumentWalker.inlines($0.blocks) } }
    func text(_ document: HDocument) -> String { inlines(document).compactMap { ($0 as? HText)?.text }.joined(separator: " ") }
}
final class EbookTestOutput: OutputAllocator {
    let stem: String
    init(_ stem: String) { self.stem = stem }
    func allocate(_ ext: String, suffix: String?) throws -> String? { stem + (suffix ?? "") + "." + ext }
}

final class EbookFoundationTests: EbookTestCase {
    func testPalmDatabaseAndDamagedTables() throws {
        let db = try PalmDatabase.open(EbookBuilders.palmDb("Old Book", "TEXtREAd", [Data([1, 2]), Data([3])]))
        XCTAssertEqual(db.name, "Old_Book"); XCTAssertEqual(db.typeCreator, "TEXtREAd"); XCTAssertEqual(db.count, 2)
        XCTAssertEqual(db.record(0), Data([1, 2])); XCTAssertEqual(db.record(1), Data([3])); XCTAssertEqual(db.record(-1), Data()); XCTAssertEqual(db.record(2), Data())
        XCTAssertEqual(PalmDatabase.u16(Data([1]), 0), 0); XCTAssertEqual(PalmDatabase.u32(Data([255, 255, 255, 255]), 0), -1)
        XCTAssertThrowsError(try PalmDatabase.open(Data()))
        var damaged = EbookBuilders.palmDb("bad", "BOOKMOBI", [Data([1])])
        BinaryPrimitives.writeUInt32BigEndian(&damaged, 78, UInt32.max)
        XCTAssertThrowsError(try PalmDatabase.open(damaged))
    }
    func testPalmDocCompressionAllByteValuesAndOverlappingReferences() {
        let data = Data((0..<256).map(UInt8.init)) + Data(String(repeating: "repeated repeated 한글 Ü ", count: 50).utf8)
        XCTAssertEqual(PalmDocCompression.decompress(EbookBuilders.palmDocCompress(data)), data)
        XCTAssertEqual(PalmDocCompression.decompress(Data([0x80, 0])), Data())
        XCTAssertEqual(PalmDocCompression.decompress(Data([3, 1, 2])), Data([1, 2]))
    }
    func testHuffCdicIdentityAndMalformedDictionaries() throws {
        let huff = try HuffCdic(EbookBuilders.identityHuff(), [EbookBuilders.identityCdic()])
        let input = Data((0..<256).map(UInt8.init))
        XCTAssertEqual(try huff.decompress(input), input)
        XCTAssertThrowsError(try HuffCdic(Data(), []))
        XCTAssertThrowsError(try HuffCdic(EbookBuilders.identityHuff(), [Data("CDIC".utf8)]))
        var recursive = EbookBuilders.identityCdic()
        BinaryPrimitives.writeUInt16BigEndian(&recursive, 16 + 512, 1)
        recursive[16 + 512 + 2] = 0
        let cycle = try HuffCdic(EbookBuilders.identityHuff(), [recursive])
        XCTAssertThrowsError(try cycle.decompress(Data([0]))) { XCTAssertEqual($0.localizedDescription, "The book's CDIC dictionary refers to itself.") }
    }
    func testMobiTrailingEntriesAndBase32() {
        XCTAssertEqual(MobiReader.trailingSize(Data([65, 66, 0, 0, 0x82]), 3), 3)
        XCTAssertEqual(MobiReader.trailingSize(Data([0xFF]), 2), 1)
        XCTAssertEqual(MobiReader.trailingSize(Data(), 3), 0)
        XCTAssertEqual(MobiReader.base32("000V"), 31); XCTAssertEqual(MobiReader.base32("0010"), 32)
        XCTAssertEqual(MobiIndex.forwardVarint(Data([1, 0x82]), 0).value, 130)
        XCTAssertEqual(MobiIndex.forwardVarint(Data(), 0).consumed, 1)
    }
    func testMobiIndexTagGroupsByteCountsAndCncxStrings() throws {
        func primary() -> Data {
            var record = Data(repeating: 0, count: 56)
            record.replaceSubrange(0..<4, with: Data("INDX".utf8))
            BinaryPrimitives.writeUInt32BigEndian(&record, 4, 56)
            BinaryPrimitives.writeUInt32BigEndian(&record, 24, 1)
            BinaryPrimitives.writeUInt32BigEndian(&record, 52, 1)
            var tagx = Data("TAGX".utf8) + Data(repeating: 0, count: 8)
            BinaryPrimitives.writeUInt32BigEndian(&tagx, 4, 28)
            BinaryPrimitives.writeUInt32BigEndian(&tagx, 8, 1)
            return record + tagx + Data([6, 2, 3, 0, 1, 1, 4, 0, 2, 1, 8, 0, 0, 0, 0, 1])
        }
        for byteCount in [false, true] {
            let payload = Data([1, 48, byteCount ? 15 : 13]) + (byteCount ? Data([0x82]) : Data()) + Data([0x82, 0x88, 0x83, 0x80])
            var record = Data(repeating: 0, count: 28)
            record.replaceSubrange(0..<4, with: Data("INDX".utf8))
            BinaryPrimitives.writeUInt32BigEndian(&record, 20, UInt32(28 + payload.count))
            BinaryPrimitives.writeUInt32BigEndian(&record, 24, 1)
            record += payload + Data("IDXT".utf8) + Data([0, 28])
            let database = try PalmDatabase.open(EbookBuilders.palmDb("index", "BOOKMOBI", [primary(), record, Data([0x83, 97, 105, 100, 0])]))
            var strings: [Int: String] = [:]
            let entries = try MobiIndex.read(database, 0, &strings)
            XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].key, "0")
            XCTAssertEqual(entries[0].tag(6, 0), 2); XCTAssertEqual(entries[0].tag(6, 1), 8)
            XCTAssertEqual(entries[0].tag(1), 3); XCTAssertEqual(entries[0].tag(2), 0); XCTAssertEqual(entries[0].tag(99), -1)
            XCTAssertEqual(strings[0], "aid")
        }
    }
    func testMobiHeaderMetadataAndAllCompressionHeaders() throws {
        for compression in [1, 2, 17480] {
            let db = try PalmDatabase.open(EbookBuilders.mobi(Data("Ünïcödé 한글".utf8), [], EbookBuilders.MobiOptions(compression: compression, cover: 2, title: "Stormy Night", author: "One & Two")))
            let header = try MobiHeader.parse(db, 0), meta = header.metadata(db.name)
            XCTAssertEqual(header.compression, compression); XCTAssertEqual(header.textLength, Data("Ünïcödé 한글".utf8).count)
            XCTAssertEqual(header.extraFlags, 3); XCTAssertEqual(header.coverOffset, 2); XCTAssertEqual(header.fdst, -1)
            XCTAssertEqual(meta.title, "Stormy Night"); XCTAssertEqual(meta.authors, ["One", "Two"]); XCTAssertEqual(meta.language, "en")
        }
    }
    func testPrintReplicaPreservesPdfBytesAndDrmError() throws {
        let pdf = Data("%PDF-1.7\nexact bytes\0".utf8)
        let path = try save("replica.azw4", EbookBuilders.printReplica(pdf))
        XCTAssertEqual(try MobiReader.printReplicaPdf(path), pdf)
        let locked = try save("locked.azw", EbookBuilders.mobi(Data("text".utf8), [], EbookBuilders.MobiOptions(encryption: 2)))
        XCTAssertThrowsError(try MobiReader.readBook(locked, folder)) { XCTAssertEqual($0.localizedDescription, EbookFiles.drmMessage) }
        let unsupported = try save("new.kfx", Data("CONT".utf8))
        XCTAssertThrowsError(try MobiReader.readBook(unsupported, folder)) { XCTAssertTrue($0.localizedDescription.contains("KFX book")) }
        let topaz = try save("old.azw", Data("TPZ".utf8))
        XCTAssertThrowsError(try MobiReader.readBook(topaz, folder)) { XCTAssertEqual($0.localizedDescription, "This is a Topaz book, which cannot be converted.") }
    }
    func testSafeExtractionSkipsTraversalAndDoesNotChangeSource() throws {
        let source = path("evil.zip"), writer = try ZipWriter(path: source)
        for name in ["../outside.txt", "inside/a.txt", "/inside/b.txt", "C:/bad.txt", "folder/../../escape.txt"] { try writer.add(name, text: name) }
        try writer.close(); let original = try Data(contentsOf: URL(fileURLWithPath: source)), target = path("extracted")
        try EbookFiles.extract(ZipReader(path: source), target)
        XCTAssertEqual(EbookFiles.safePath("/", "inside"), "/inside")
        XCTAssertNil(EbookFiles.safePath(target, "../outside.txt")); XCTAssertNil(EbookFiles.safePath(target, "C:/bad"))
        XCTAssertEqual(EbookFiles.files(target).count, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source)), original)
    }
    func testOpfSpineMetadataCoverAndDuplicateIds() throws {
        let epub = try EbookBuilders.epub(folder), extracted = path("package")
        try EbookFiles.extract(ZipReader(path: epub), extracted)
        let opf = try OpfPackage.load(OpfPackage.rootFile(extracted))
        XCTAssertEqual(opf.metadata.title, "별빛 이야기"); XCTAssertEqual(opf.metadata.authors, ["김작가"]); XCTAssertEqual(opf.metadata.language, "ko")
        XCTAssertTrue(opf.metadata.coverImage?.hasSuffix("cover.png") == true)
        XCTAssertEqual(opf.spine.map { FilePath.fileName($0.path) }, ["ch1.xhtml", "ch2.xhtml", "ch 3.xhtml"])
        let xml = try OpfPackage.metadataOnly(opf.metadata, "A<&", "ko")
        XCTAssertEqual(try XDocument.parse(xml).root.descendants().first { $0.name.localName == "title" }?.value, "A<&")
        let duplicate = try save("dup.opf", Data("<package><metadata/><manifest><item id='x' href='first'/><item id='x' href='second'/></manifest><spine><itemref idref='x'/></spine></package>".utf8))
        XCTAssertEqual(try OpfPackage.load(duplicate).spine.first?.path, path("first"))
    }
    func testEpubDrmAllowsOnlyFontObfuscation() throws {
        for (index, algorithm) in ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC", "http://www.w3.org/2001/04/xmlenc#aes128-cbc"].enumerated() {
            let zipPath = path("drm\(index).epub"), zip = try ZipWriter(path: zipPath)
            try zip.add("META-INF/encryption.xml", text: "<encryption><EncryptionMethod Algorithm='\(algorithm)'/></encryption>"); try zip.close()
            if index < 2 { XCTAssertNoThrow(try EpubReader.checkDrm(ZipReader(path: zipPath))) }
            else { XCTAssertThrowsError(try EpubReader.checkDrm(ZipReader(path: zipPath))) { XCTAssertEqual($0.localizedDescription, EbookFiles.drmMessage) } }
        }
    }
    func testPlainTextParagraphsAndHardWrapping() {
        let text = "This is a line with a length between fifty and a hundred characters.\n  This continues on another line of similar length with a space.\n\nNext paragraph"
        let doc = PlainText.toDocument(text), paragraphs = doc.sections[0].blocks.compactMap { $0 as? HParagraph }
        XCTAssertEqual(paragraphs.count, 2); XCTAssertFalse(paragraphs[0].inlines.contains { $0 is HLineBreak })
        XCTAssertTrue(HDocumentWalker.text(paragraphs[0].inlines).contains("characters. This"))
        let lines = PlainText.toDocument("one\ntwo"); XCTAssertEqual(lines.sections[0].blocks.count, 2)
        let manual = PlainText.toDocument("one\ntwo\n\nthree"); XCTAssertTrue((manual.sections[0].blocks[0] as! HParagraph).inlines.contains { $0 is HLineBreak })
    }
    func testFb2LegacyEncodingNotesPoemsTablesAndWriterRoundTrip() throws {
        let book = try Fb2Reader.readBook(EbookBuilders.fb2(folder), folder)
        XCTAssertEqual(book.metadata.title, "Война и мир"); XCTAssertEqual(book.metadata.authors, ["Лев Толстой"])
        XCTAssertEqual(book.metadata.language, "ru"); XCTAssertNotNil(book.metadata.coverImage)
        let all = inlines(book.document)
        XCTAssertTrue(all.contains { ($0 as? HText)?.format.bold == true }); XCTAssertTrue(all.contains { $0 is HNote })
        XCTAssertTrue(all.contains { $0 is HLineBreak }); XCTAssertTrue(book.document.sections[0].blocks.contains { $0 is HTable })
        let output = path("roundtrip.fb2"); try Fb2Writer.write(book, output, "source.fb2", folder)
        let xml = try XDocument.load(output)
        XCTAssertEqual(xml.root.name.localName, "FictionBook")
        XCTAssertEqual(xml.root.elements().filter { $0.name.localName == "binary" }.count, 1)
        let round = try Fb2Reader.readBook(output, folder)
        XCTAssertEqual(round.metadata.title, book.metadata.title); XCTAssertEqual(round.metadata.authors, book.metadata.authors)
        for expected in ["Первый", "Текст примечания.", "Строка стиха один", "Текст подглавы."] { XCTAssertTrue(text(round.document).contains(expected), expected) }
    }
    func testBookTitleLanguageAndFb2XmlCleaning() throws {
        let document = HDocument(), section = HSection(), heading = HParagraph(), paragraph = HParagraph()
        document.sections.append(section); heading.headingLevel = 1; heading.inlines = [HText("첫 제목")]
        paragraph.inlines = [HText("안녕하세요 \u{000B} <&> 😀", HCharFormat(bold: true, italic: true))]
        section.blocks = [heading, paragraph]
        let metadata = BookMetadata(), book = Book(document, metadata)
        XCTAssertEqual(book.displayTitle("file.epub"), "첫 제목"); XCTAssertEqual(book.displayLanguage(), "ko")
        document.title = " Document "; XCTAssertEqual(book.displayTitle("file.epub"), "Document")
        metadata.title = " Metadata "; metadata.language = " en-US "
        XCTAssertEqual(book.displayTitle("file.epub"), "Metadata"); XCTAssertEqual(book.displayLanguage(), "en-US")
        let output = path("clean.fb2"); try Fb2Writer.write(book, output, "file.epub", folder)
        let xml = try XDocument.load(output)
        XCTAssertTrue(xml.root.value.contains("안녕하세요  <&> 😀")); XCTAssertFalse(xml.root.value.contains("\u{000B}"))
        XCTAssertTrue(xml.root.descendants().contains { $0.name.localName == "strong" && $0.value.contains("😀") })
    }
    func testEpubPackageNavigationCoverDedupAndInsertionOrder() throws {
        let cover = try save("cover.png", EbookBuilders.picture(12, 20))
        let metadata = BookMetadata(); metadata.authors = ["First Author", "Second Author"]; metadata.publisher = "A&B"; metadata.description = "<description>"
        let package = EpubPackage("A<&", "ko-KR", metadata)
        let image = try XCTUnwrap(package.addImage(cover, folder))
        XCTAssertEqual(package.addImage(cover, folder, true), image)
        package.addPage("first.xhtml", XhtmlWriter.page("First", "<h1>First</h1>", "ko", "style.css", true))
        package.addPage("second.xhtml", XhtmlWriter.page("Second", "<h1>Second</h1>", "ko", "style.css", true))
        package.toc = [XhtmlHeading(level: 1, text: "First", target: "first.xhtml"), XhtmlHeading(level: 2, text: "Sub", target: "first.xhtml#sub"), XhtmlHeading(level: 1, text: "Second", target: "second.xhtml")]
        let output = path("toc.epub"); try package.save(output, "body{}", false)
        let zip = try ZipReader(path: output)
        XCTAssertEqual(zip.entries.map(\.name), ["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/style.css", "OEBPS/first.xhtml", "OEBPS/second.xhtml", "OEBPS/images/img0001.png"])
        let opf = try XDocument.parse(XCTUnwrap(zip.string(named: "OEBPS/content.opf")))
        XCTAssertEqual(opf.root.descendants().filter { $0.name.localName == "creator" }.map(\.value), metadata.authors)
        XCTAssertEqual(opf.root.descendants().filter { $0.attributeValue("properties") == "cover-image" }.count, 1)
        let nav = try XDocument.parse(XCTUnwrap(zip.string(named: "OEBPS/nav.xhtml"))), ncx = try XDocument.parse(XCTUnwrap(zip.string(named: "OEBPS/toc.ncx")))
        XCTAssertTrue(nav.root.value.contains("목차")); XCTAssertEqual(ncx.root.descendants().filter { $0.name.localName == "navPoint" }.count, 3)
    }
    func testCbcWithoutReadingListPreservesNaturalBookOrder() async throws {
        let a = path("a.cbz"), b = path("b.cbz")
        for (file, width) in [(b, 40), (a, 20)] {
            let zip = try ZipWriter(path: file); try zip.add("page.png", data: EbookBuilders.picture(width, 30)); try zip.close()
        }
        let collection = path("collection.cbc"), zip = try ZipWriter(path: collection)
        try zip.add("b.cbz", contentsOf: b); try zip.add("a.cbz", contentsOf: a); try zip.close()
        let pages = try await ComicBook.extractPages(collection, "cbc", EbookFiles.newFolder(folder, "collection"))
        XCTAssertEqual(pages.compactMap { ImageSupport.info($0)?.width }, [20, 40])
    }
    func testNaturalComparer() {
        let names = ["p10", "p02", "P1", "p2", "p000", "p0", "p999999999999999999999999"]
        XCTAssertEqual(names.sorted { NaturalComparer.compare($0, $1) < 0 }, ["p000", "p0", "P1", "p02", "p2", "p10", "p999999999999999999999999"])
        XCTAssertLessThan(NaturalComparer.compare("x😀", "x😁"), 0)
        XCTAssertEqual(NaturalComparer.compare(nil, nil), 0); XCTAssertEqual(NaturalComparer.compare(nil, "x"), -1)
    }
    func testComicsPdfFixedLayoutAndPdfCbz() async throws {
        let input = try EbookBuilders.cbz(folder), pages = try await ComicBook.extractPages(input, "cbz", folder)
        XCTAssertEqual(pages.compactMap { ImageSupport.info($0)?.width }, [200, 220, 240])
        let pdf = try await convert(input, "cbz", "pdf"), document = try XCTUnwrap(PDFDocument(url: URL(fileURLWithPath: pdf)))
        XCTAssertEqual(document.pageCount, 3)
        for i in 0..<3 { XCTAssertEqual(document.page(at: i)!.bounds(for: .mediaBox).width, Double(EbookBuilders.comicPages[i].1) * 72 / (i == 1 ? 72 : 96), accuracy: 0.1) }
        let epub = try await convert(input, "cbz", "epub"), zip = try ZipReader(path: epub)
        XCTAssertEqual(zip.entries.first?.name, "mimetype"); XCTAssertEqual(zip.entries.first?.method, 0)
        let package = try XCTUnwrap(zip.string(named: "OEBPS/content.opf"))
        XCTAssertTrue(package.contains("pre-paginated")); XCTAssertEqual(zip.entries.filter { $0.name.hasSuffix(".xhtml") }.count, 4)
        var preset = Preset(); preset.pdf.renderDpi = 96
        let cbz = try await convert(pdf, "pdf", "cbz", preset), back = try ZipReader(path: cbz)
        XCTAssertEqual(back.entries.map(\.name), ["001.jpg", "002.jpg", "003.jpg"])
        let first = try save("page.jpg", XCTUnwrap(back.data(named: "001.jpg")))
        XCTAssertEqual(ImageSupport.info(first)?.width, 200)
    }
    func testCb7AndCbtExtraction() async throws {
        guard let sevenZip = EngineEnvironment.bundledProgram("7zip", "7zz") else { throw XCTSkip("bundled 7-Zip not found") }
        let source = path("comics"); try FileManager.default.createDirectoryIfNeeded(source)
        for (name, width, height) in EbookBuilders.comicPages {
            let file = FilePath.combine(source, name); try FileManager.default.createDirectoryIfNeeded(FilePath.directoryName(file)!)
            try EbookBuilders.picture(width, height, name.hasSuffix(".jpg")).write(to: URL(fileURLWithPath: file))
        }
        for (format, type) in [("cb7", "7z"), ("cbt", "tar")] {
            let archive = path("comic." + format)
            let result = try await ProcessRunner.run(sevenZip, ["a", "-t" + type, archive, "chapter"], timeout: 30, workingDirectory: source)
            XCTAssertEqual(result.exitCode, 0)
            let work = try EbookFiles.newFolder(folder, format), pages = try await ComicBook.extractPages(archive, format, work)
            XCTAssertEqual(pages.compactMap { ImageSupport.info($0)?.width }, [200, 220, 240])
            let output = FilePath.combine(work, "repacked.cbz"); try ComicBook.toCbz(pages, output)
            XCTAssertEqual(try ZipReader(path: output).entries.map(\.name), ["001.png", "002.jpg", "003.png"])
        }
    }
    func testPreCancelledPrintReplicaDoesNotWriteAnOutput() async throws {
        let input = try save("replica.azw4", EbookBuilders.printReplica(Data("%PDF-1.7".utf8)))
        let destination = path("cancelled"), work = folder!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let step = ConversionStep(inputPath: input, from: "azw4", to: "pdf", preset: Preset(), output: EbookTestOutput(destination), workDirectory: work)
            return try await EbookConverter().convert(step, progress: nil)
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(destination + ".pdf"))
    }
    func testCalibreProgressAndTail() {
        let values = EbookProgressBox()
        for line in [" 34% Running transforms", "100% done", "999% limit", "noise"] { CalibreConverter.reportProgress(line, { values.add($0) }) }
        XCTAssertEqual(values.values, [0.323, 0.95, 0.95])
        XCTAssertEqual(CalibreConverter.lastLines(" one\n\n two \n three\n four \n"), "two three four")
    }
    func testEbookAndCalibreEdgesPreserveFileeOrderAndCosts() {
        let edges = EbookConverter().edges
        XCTAssertEqual(edges.prefix(4).map(\.to), ["hwpx", "txt", "html", "md"])
        XCTAssertEqual(edges.first { $0.from == "epub" && $0.to == "md" }?.cost, 12)
        XCTAssertEqual(edges.suffix(2).map { "\($0.from):\($0.to):\($0.cost)" }, ["pdf:cbz:15", "azw4:pdf:10"])
        XCTAssertFalse(edges.contains { $0.to == "mobi" })
        XCTAssertEqual(CalibreConverter().edges, CalibreConverter.inputs.map { ConversionEdge($0, "epub", 20) } + CalibreConverter.outputs.map { ConversionEdge("epub", $0, 20) })
    }
}
final class EbookProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [Double] = []
    func add(_ value: Double) { lock.withLock { storage.append(value) } }
    var values: [Double] { lock.withLock { storage } }
}
