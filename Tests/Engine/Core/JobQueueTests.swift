import XCTest
@testable import FileToXEngineKit

final class JobQueueTests: XCTestCase {
    func testConvertsEveryFileAndKeepsDates() async throws {
        let d = CoreTempDir(), a = try d.file("a.jpg"), b = try d.file("b.jpg")
        let modified = Date(timeIntervalSince1970: 1_562_000_000), created = modified.addingTimeInterval(-86400)
        try FileManager.default.setAttributes([.creationDate:created,.modificationDate:modified], ofItemAtPath:a)
        let queue = JobQueue(ConverterCatalog([CoreFakeConverter("magick",ConversionEdge("jpg","png"))]))
        let job = await coreRun(queue,[a,b],corePreset("png") { $0.output.keepDates = true })
        XCTAssertEqual(job.state,.completed); XCTAssertEqual(job.progress,1); XCTAssertEqual(job.outputs.count,2)
        let attributes = try FileManager.default.attributesOfItem(atPath:d.path + "/a.png")
        XCTAssertEqual(attributes[.modificationDate] as? Date,modified); XCTAssertEqual(attributes[.creationDate] as? Date,created)
    }
    func testMultiStepAndPerFileFailures() async throws {
        let d = CoreTempDir(), c = CoreFakeConverter("pdfium",ConversionEdge("pdf","png")); c.outputsPerInput = 2
        let q = JobQueue(ConverterCatalog([CoreFakeConverter("rhwp",ConversionEdge("hwpx","pdf")),c]))
        let j = await coreRun(q,[try d.file("doc.hwpx")],corePreset("png"))
        XCTAssertEqual(j.state,.completed); XCTAssertEqual(try d.names(),["doc.hwpx","doc_p1.png","doc_p2.png"])
        let broken = await coreRun(q,[try d.file("a.pdf"),try d.file("b.xyz")],corePreset("png"))
        XCTAssertEqual(broken.state,.completedWithErrors); XCTAssertEqual(broken.files[1].errorKey,"error.unsupported_source")
        let noRoute = await coreRun(q,[try d.file("a.docx")],corePreset("hwpx")); XCTAssertEqual(noRoute.files[0].errorKey,"error.no_route")
        c.shouldThrow = true
        let failed = await coreRun(q,[try d.file("boom.pdf")],corePreset("png")); XCTAssertEqual(failed.files[0].errorDetail,"boom"); XCTAssertEqual(failed.files[0].errorKey,"error.conversion_failed")
    }
    func testPdfWithoutTextReplansOnceForPagePictureFormatsOnly() async throws {
        let d = CoreTempDir(), lock = NSLock(), scan = try d.file("scan.pdf")
        var log: [String] = [], keeping: [Bool] = [], outcome: () throws -> Void = { throw NoTextError("no text") }
        let text = CoreFakeConverter(edges:[ConversionEdge("pdf","txt",isTextExtraction:true)]) { step in lock.withLock { log.append("pdf→txt"); keeping.append(step.keepsPages) }; try outcome(); return [] }
        let documents = CoreFakeConverter(edges:[ConversionEdge("pdf","docx",14),ConversionEdge("docx","epub"),ConversionEdge("txt","epub"),ConversionEdge("docx","mobi"),ConversionEdge("txt","mobi"),ConversionEdge("txt","fb2")]) { step in
            lock.withLock { log.append(step.from + "→" + step.to); keeping.append(step.keepsPages) }
            guard let output = try step.output.allocate(step.to) else { return [] }
            try Data("converted".utf8).write(to:URL(fileURLWithPath:output)); return [output]
        }
        let q = JobQueue(ConverterCatalog([text,documents]))
        let pages = await coreRun(q,[scan],corePreset("epub"))
        XCTAssertEqual(pages.state,.completed); XCTAssertEqual(log,["pdf→txt","pdf→docx","docx→epub"]); XCTAssertEqual(pages.outputs,[d.path + "/scan.epub"])
        // Both routes are told the pages can be kept: the text step reports pages it would leave out, the page reader keeps text.
        XCTAssertEqual(keeping,[true,true,true])
        // TXT, excluded targets and targets with no alternative route keep the explicit failure.
        for format in ["txt","mobi","fb2"] {
            log = []; keeping = []
            let failed = await coreRun(q,[scan],corePreset(format))
            XCTAssertEqual(failed.files[0].errorKey,"error.conversion_failed",format); XCTAssertEqual(failed.files[0].errorDetail,"no text",format); XCTAssertEqual(log,["pdf→txt"],format); XCTAssertEqual(keeping,[false],format)
        }
        // Other failures and cancellation are never read as "no text", and a cancelled job does not start the re-plan.
        log = []; outcome = { throw ConversionError("broken") }
        let broken = await coreRun(q,[scan],corePreset("epub")); XCTAssertEqual(broken.files[0].errorDetail,"broken")
        outcome = { throw CancellationError() }
        let stopped = await coreRun(q,[scan],corePreset("epub")); XCTAssertEqual(stopped.files[0].state,.cancelled)
        let cancelled = ConversionJob([scan],corePreset("epub"),"Test"); outcome = { cancelled.cancel(); throw NoTextError("no text") }
        await q.run(cancelled)
        XCTAssertEqual(cancelled.state,.cancelled); XCTAssertEqual(cancelled.files[0].state,.cancelled); XCTAssertEqual(log,["pdf→txt","pdf→txt","pdf→txt"])
        XCTAssertEqual(try d.names(),["scan.epub","scan.pdf"]); XCTAssertEqual(try d.read("scan.pdf"),"x"); XCTAssertEqual(d.leftovers(),[])
    }
    func testPdfTextDoesNotReplanThroughAComicsOnlyRoute() async throws {
        let d = CoreTempDir(), lock = NSLock(), scan = try d.file("scan.pdf")
        var keeping: [Bool] = []
        let text = CoreFakeConverter(edges: [ConversionEdge("pdf", "txt", isTextExtraction: true)]) { step in
            lock.withLock { keeping.append(step.keepsPages) }
            if step.keepsPages { throw NoTextError("has pictures") }
            let output = try XCTUnwrap(step.output.allocate("txt"))
            try Data("Recognised words".utf8).write(to: URL(fileURLWithPath: output))
            return [output]
        }
        let pages = CoreFakeConverter(edges: [ConversionEdge("pdf", "docx", 14), ConversionEdge("docx", "epub"),
                                             ConversionEdge("pdf", "cbz", 12), ConversionEdge("cbz", "epub"), ConversionEdge("txt", "epub")]) { step in
            let output = try XCTUnwrap(step.output.allocate(step.to))
            try Data(contentsOf: URL(fileURLWithPath: step.inputPath)).write(to: URL(fileURLWithPath: output))
            return [output]
        }
        let catalog = ConverterCatalog([text, pages]), planner = catalog.createPlanner()
        XCTAssertEqual(planner.plan("pdf", "epub")?.steps.map(\.to), ["txt", "epub"])
        XCTAssertEqual(planner.plan("pdf", "epub", textExtraction: false)?.steps.map(\.to), ["cbz", "epub"])
        let job = await coreRun(JobQueue(catalog), [scan], corePreset("epub"))
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(keeping, [false])
        XCTAssertEqual(try d.read("scan.epub"), "Recognised words")
    }
    func testSameSourceAndParallelNames() async throws {
        let d = CoreTempDir(), source = try d.file("a.jpg")
        let c = CoreFakeConverter("magick",ConversionEdge("jpg","jpg"),ConversionEdge("jpg","webp"),ConversionEdge("png","webp")), q = JobQueue(ConverterCatalog([]))
        _ = q
        let queue = JobQueue(ConverterCatalog([c]))
        let job = await coreRun(queue,[source],corePreset("*") { $0.output.fileNamePattern = "{name}_50" })
        XCTAssertEqual(job.state,.completed); XCTAssertTrue(FileManager.default.fileExists(d.path + "/a_50.jpg")); XCTAssertEqual(try d.read("a.jpg"),"x")
        let parallel = await coreRun(queue,[try d.file("same.jpg"),try d.file("same.png")],corePreset("webp"))
        XCTAssertEqual(Set(parallel.outputs).count,2)
    }
    func testMergeAndMultiPageTiffPreserveInputOrder() async throws {
        let d = CoreTempDir(), merger = CoreFakeMerger()
        let catalog = ConverterCatalog([CoreFakeConverter("pdfsharp",ConversionEdge("jpg","pdf"),ConversionEdge("png","pdf"))])
        let q = JobQueue(catalog,pdfMerger:merger)
        let second = try d.file("2.pdf")
        let job = await coreRun(q,[try d.file("1.jpg"),second,try d.file("3.png")],corePreset("pdf") { $0.pdf.mergeIntoSingle = true; $0.output.fileNamePattern = "{name}_merged" })
        XCTAssertEqual(job.state,.completed); XCTAssertEqual(try d.read("1_merged.pdf"),"1.pdf|2.pdf|3.pdf"); XCTAssertEqual(merger.inputs[1],second)
        let pages = CoreFakeConverter("pdfium",ConversionEdge("pdf","tiff")); pages.outputsPerInput = 2
        let tq = JobQueue(ConverterCatalog([pages,CoreFakeConverter("magick",ConversionEdge("jpg","tiff"))]),tiffMerger:merger)
        let fax = try d.file("fax.tiff")
        let tiff = await coreRun(tq,[try d.file("scan.pdf"),try d.file("photo.jpg"),fax],corePreset("tiff") { $0.image.multiPageTiff = true })
        XCTAssertEqual(tiff.state,.completed); XCTAssertEqual(tiff.outputs,[d.path + "/scan.tiff"])
        XCTAssertEqual(merger.inputs.map(FilePath.fileName),["scan_p1.tiff","photo.tiff","fax.tiff"].flatMap { $0 == "scan_p1.tiff" ? [$0,"scan_p2.tiff"] : [$0] }); XCTAssertEqual(merger.inputs.last,fax)
    }
    func testCombineUnknownSingleCompoundExtensionsAndFailures() async throws {
        let d = CoreTempDir(), combiner = CoreFakeCombiner(), q = JobQueue(ConverterCatalog([]),combiner:CoreFakeCombiner())
        let queue = JobQueue(ConverterCatalog([]),combiner:combiner)
        let a = try d.file("report.docx"), b = try d.file("data.xyz")
        let preset = corePreset("zip") { $0.archive.combineIntoOne = true; $0.output.fileNamePattern = "{name}_files" }
        let job = await coreRun(queue,[a,b],preset)
        XCTAssertEqual(job.state,.completed); XCTAssertEqual(combiner.inputs,[a,b]); XCTAssertEqual(job.outputs,[d.path + "/report_files.zip"])
        let single = await coreRun(queue,[b],preset); XCTAssertEqual(single.outputs,[d.path + "/data_files.zip"])
        let tgz = await coreRun(q,[try d.file("a.txt")],corePreset("tgz") { $0.archive.combineIntoOne = true }); XCTAssertEqual(tgz.outputs,[d.path + "/a.tar.gz"])
        combiner.shouldThrow = true
        let failure = await coreRun(queue,[a,b],preset); XCTAssertEqual(failure.state,.failed); XCTAssertTrue(failure.files.allSatisfy { $0.errorDetail == "boom" })
        let ordinary = JobQueue(ConverterCatalog([CoreFakeConverter("archive",ConversionEdge("rar","zip"))]),combiner:combiner)
        let converted = await coreRun(ordinary,[try d.file("a.rar"),try d.file("b.rar")],corePreset("zip")); XCTAssertEqual(converted.outputs.count,2)
    }
    func testEnqueueAndCancellationAndEngineGates() async throws {
        let d = CoreTempDir(), done = expectation(description:"finished"), q = JobQueue(ConverterCatalog([CoreFakeConverter("fake",ConversionEdge("jpg","png"))]))
        q.jobFinished = { job in XCTAssertEqual(job.state,.completed); done.fulfill() }
        q.enqueue([try d.file("a.jpg")],corePreset("png"),"PNG")
        await fulfillment(of:[done],timeout:10); await q.dispose()
        let lock = NSLock(); var active = 0, maximum = 0
        let engine = CoreFakeConverter(edges:[ConversionEdge("jpg","png")]) { step in
            lock.withLock { active += 1; maximum = max(maximum,active) }
            defer { lock.withLock { active -= 1 } }
            try await Task.sleep(nanoseconds:5_000_000)
            guard let output = try step.output.allocate("png") else { return [] }; try Data("x".utf8).write(to:URL(fileURLWithPath:output)); return [output]
        }; engine.maxParallelism = 1
        let paths = try (0..<8).map { try d.file("gate\($0).jpg") }
        let gated = await coreRun(JobQueue(ConverterCatalog([engine])),paths,corePreset("png")); XCTAssertEqual(gated.state,.completed); XCTAssertEqual(maximum,1)
    }
    func testQueuedJobsAreSerialAndQueuedCancellationFinishesOnce() async throws {
        let d = CoreTempDir(), firstStarted = expectation(description:"first started"), done = expectation(description:"two jobs finished")
        done.expectedFulfillmentCount = 2
        let lock = NSLock(); var active = 0, maximum = 0, finished: [String] = []
        let c = CoreFakeConverter(edges:[ConversionEdge("jpg","png")]) { step in
            lock.withLock { active += 1; maximum = max(maximum,active) }
            defer { lock.withLock { active -= 1 } }
            firstStarted.fulfill(); try await Task.sleep(nanoseconds:50_000_000)
            guard let path = try step.output.allocate("png") else { return [] }
            try Data("x".utf8).write(to:URL(fileURLWithPath:path)); return [path]
        }
        let q = JobQueue(ConverterCatalog([c])); q.jobFinished = { job in lock.withLock { finished.append(job.id) }; done.fulfill() }
        let source = try d.file("serial.jpg"), first = q.enqueue([source],corePreset("png"),"first")
        await fulfillment(of:[firstStarted],timeout:5)
        let second = q.enqueue([source],corePreset("png"),"second"); second.cancel()
        await fulfillment(of:[done],timeout:5); await q.dispose()
        XCTAssertEqual(maximum,1); XCTAssertEqual(finished,[first.id,second.id]); XCTAssertEqual(second.state,.cancelled); XCTAssertEqual(second.files[0].state,.pending)
    }

}
