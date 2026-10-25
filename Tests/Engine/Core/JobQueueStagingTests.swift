import XCTest
@testable import FileToXEngineKit

final class JobQueueStagingTests: XCTestCase {
    func testBlockedOutputCheckDoesNotHoldEnqueueLockAndCancellationCleansReservations() async throws {
        let d = CoreTempDir(), checking = expectation(description: "disk check blocked"), enqueued = expectation(description: "enqueue returned")
        let done = expectation(description: "both cancelled"); done.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let q = JobQueue(ConverterCatalog([CoreFakeConverter("fake", ConversionEdge("jpg", "png"))]), outputExists: { _ in
            checking.fulfill(); _ = release.wait(timeout: .now() + 8); return true
        })
        q.jobFinished = { job in XCTAssertEqual(job.state, .cancelled); done.fulfill() }
        let source = try d.file("source.jpg"), first = q.enqueue([source], corePreset("png"), "first")
        await fulfillment(of: [checking], timeout: 2)
        DispatchQueue.global().async {
            let second = q.enqueue([source], corePreset("png"), "second")
            second.cancel(); first.cancel(); enqueued.fulfill()
        }
        await fulfillment(of: [enqueued], timeout: 1)
        release.signal()
        await fulfillment(of: [done], timeout: 3); await q.dispose()
        XCTAssertEqual(try d.names(), ["source.jpg"])
        XCTAssertTrue(d.leftovers().isEmpty)
    }

    func testParallelReservationsRemainDistinctAfterRacingDiskChecksIncludingOverwrite() async throws {
        for conflict in [ConflictPolicy.rename, .overwrite] {
            let d = CoreTempDir(), checked = expectation(description: "both checked same path"), allocated = expectation(description: "both reserved")
            checked.expectedFulfillmentCount = 2; allocated.expectedFulfillmentCount = 2
            let releaseCheck = DispatchSemaphore(value: 0), releaseConversion = DispatchSemaphore(value: 0), lock = NSLock()
            var checks = 0
            let c = CoreFakeConverter(edges: [ConversionEdge("jpg", "png")]) { step in
                let path = try XCTUnwrap(step.output.allocate("png"))
                try Data(FilePath.fileName(step.inputPath).utf8).write(to: URL(fileURLWithPath: path))
                allocated.fulfill(); _ = releaseConversion.wait(timeout: .now() + 8)
                return [path]
            }
            let q = JobQueue(ConverterCatalog([c]), outputExists: { path in
                let block = lock.withLock { () -> Bool in
                    guard FilePath.fileName(path) == "same.png" else { return false }
                    checks += 1; return checks <= 2
                }
                if block { checked.fulfill(); _ = releaseCheck.wait(timeout: .now() + 8) }
                return false
            })
            let p = corePreset("png") { $0.output.fileNamePattern = "same"; $0.output.conflict = conflict }
            let first = ConversionJob([try d.file("one.jpg")], p, "one"), second = ConversionJob([try d.file("two.jpg")], p, "two")
            let a = Task { await q.run(first) }, b = Task { await q.run(second) }
            await fulfillment(of: [checked], timeout: 2)
            releaseCheck.signal(); releaseCheck.signal()
            await fulfillment(of: [allocated], timeout: 2)
            releaseConversion.signal(); releaseConversion.signal()
            await a.value; await b.value
            XCTAssertEqual(first.state, .completed); XCTAssertEqual(second.state, .completed)
            XCTAssertEqual(Set(first.outputs + second.outputs), [d.path + "/same.png", d.path + "/same (2).png"])
            XCTAssertEqual(Set(try (first.outputs + second.outputs).map { try String(contentsOfFile: $0, encoding: .utf8) }), ["one.jpg", "two.jpg"])
            XCTAssertTrue(d.leftovers().isEmpty)
        }
    }
    private func converter(_ from: String = "jpg", _ to: String = "png", _ script: @escaping (ConversionStep) throws -> [String]) -> CoreFakeConverter { CoreFakeConverter(edges:[ConversionEdge(from,to)],script:{ try script($0) }) }
    private func write(_ path: String, _ text: String) throws -> String { try Data(text.utf8).write(to:URL(fileURLWithPath:path)); return path }
    func testFailureAfterPagesReleasesNamesAndJournalPaths() async throws {
        let d = CoreTempDir(), source = try d.file("doc.pdf"); var fail = true, staged: [String] = []
        let c = converter("pdf","png") { step in try (1...3).map { page in if page == 3 && fail { throw ConversionError("boom") }; return try self.write(step.output.allocate("png",suffix:"_p\(page)")!,"page") } }
        let q = JobQueue(ConverterCatalog([c]),onStaging:{ staged.append($0) })
        let failed = await coreRun(q,[source],corePreset("png"))
        XCTAssertEqual(failed.files[0].state,.failed); XCTAssertTrue(failed.outputs.isEmpty); XCTAssertEqual(try d.names(),["doc.pdf"]); XCTAssertTrue(d.leftovers().isEmpty); XCTAssertEqual(staged.count,2); XCTAssertTrue(staged.allSatisfy { OutputCommit.isStagingFolderName(FilePath.fileName($0)) })
        fail = false
        let again = await coreRun(q,[source],corePreset("png")); XCTAssertEqual(again.outputs,(1...3).map { d.path + "/doc_p\($0).png" })
    }
    func testFailedAndSuccessfulOverwrite() async throws {
        let d = CoreTempDir(), source = try d.file("a.jpg"), existing = try d.file("a.png","old")
        let c = converter { step in _ = try self.write(step.output.allocate("png")!,"half"); throw ConversionError("boom") }
        let preset = corePreset("png") { $0.output.conflict = .overwrite }
        let failed = await coreRun(JobQueue(ConverterCatalog([c])),[source],preset)
        XCTAssertEqual(failed.files[0].state,.failed); XCTAssertEqual(try d.read("a.png"),"old"); XCTAssertTrue(d.leftovers().isEmpty)
        let success = converter { [try self.write($0.output.allocate("png")!,"new")] }
        let done = await coreRun(JobQueue(ConverterCatalog([success])),[source],preset)
        XCTAssertEqual(done.outputs,[existing]); XCTAssertEqual(try d.read("a.png"),"new")
    }
    func testSideFilesAndConflictingSideFolderPreflight() async throws {
        let d = CoreTempDir(), source = try d.file("x.docx")
        let c = converter("docx","html") { step in
            let output = try step.output.allocate("html")!
            XCTAssertEqual(OutputCommit.finalPath(of:output),d.path + "/x.html")
            let media = FilePath.combine(FilePath.directoryName(output)!,"x_files")
            try FileManager.default.createDirectoryIfNeeded(media); _ = try self.write(media + "/img.png","img")
            return [try self.write(output,"<img src=\"x_files/img.png\">")]
        }
        try d.file("x_files/keep.txt","mine")
        let q = JobQueue(ConverterCatalog([c]))
        let failed = await coreRun(q,[source],corePreset("html"))
        XCTAssertEqual(failed.files[0].errorKey,"error.output_exists"); XCTAssertTrue(failed.outputs.isEmpty); XCTAssertFalse(FileManager.default.fileExists(d.path + "/x.html")); XCTAssertTrue(d.leftovers().isEmpty)
        let done = await coreRun(q,[source],corePreset("html") { $0.output.conflict = .overwrite })
        XCTAssertEqual(done.outputs,[d.path + "/x.html"]); XCTAssertEqual(try d.read("x_files/keep.txt"),"mine"); XCTAssertEqual(try d.read("x_files/img.png"),"img")
        XCTAssertEqual(OutputCommit.finalPath(of:"/elsewhere/y.html"),"/elsewhere/y.html")
    }
    func testSecondOutputFailureKeepsFirst() async throws {
        let d = CoreTempDir(), source = try d.file("s.pdf")
        try FileManager.default.createDirectoryIfNeeded(d.path + "/s_p2.png")
        let c = converter("pdf","png") { step in try (1...2).map { try self.write(step.output.allocate("png",suffix:"_p\($0)")!,"page") } }
        let job = await coreRun(JobQueue(ConverterCatalog([c])),[source],corePreset("png") { $0.output.conflict = .overwrite })
        XCTAssertEqual(job.files[0].state,.failed); XCTAssertEqual(job.outputs,[d.path + "/s_p1.png"]); XCTAssertEqual(job.files[0].errorKey,"error.output_commit_failed"); XCTAssertTrue(d.leftovers().isEmpty)
    }
    func testRacingOutputIsNotOverwritten() async throws {
        let d = CoreTempDir(), source = try d.file("a.jpg")
        let c = converter { step in let output = try step.output.allocate("png")!; try d.file("a.png","theirs"); return [try self.write(output,"ours")] }
        let job = await coreRun(JobQueue(ConverterCatalog([c])),[source],corePreset("png"))
        XCTAssertEqual(job.files[0].errorKey,"error.output_exists"); XCTAssertEqual(try d.read("a.png"),"theirs"); XCTAssertTrue(job.outputs.isEmpty)
    }
    func testSourceProtectedThroughSymlinkHardLinkUnicodeAndDirectoryMerge() async throws {
        let d = CoreTempDir(), source = try d.file("한글.txt".precomposedStringWithCanonicalMapping,"original")
        try FileManager.default.createSymbolicLink(atPath:d.path + "/alias",withDestinationPath:d.path)
        let c = converter("txt","txt") { [try self.write($0.output.allocate("txt")!,"replaced")] }
        let job = await coreRun(JobQueue(ConverterCatalog([c])),[source],corePreset("*") { $0.output.location = .customFolder; $0.output.customFolder = d.path + "/alias"; $0.output.conflict = .overwrite })
        XCTAssertEqual(job.files[0].errorKey,"error.output_is_source"); XCTAssertEqual(try d.read("한글.txt"),"original"); XCTAssertTrue(d.leftovers().isEmpty)
        try FileManager.default.linkItem(atPath:source,toPath:d.path + "/hard.txt")
        XCTAssertTrue(OutputCommit.isSource(d.path + "/hard.txt",[source]))
        try d.file("pack/keep.txt","mine"); try d.file("pack/same.txt","old")
        let unpack = converter("zip","folder") { step in let output = try step.output.allocate("")!; try FileManager.default.createDirectoryIfNeeded(output); _ = try self.write(output + "/same.txt","new"); return [output] }
        let done = await coreRun(JobQueue(ConverterCatalog([unpack])),[try d.file("pack.zip")],corePreset("folder") { $0.output.conflict = .overwrite })
        XCTAssertEqual(done.outputs,[d.path + "/pack"]); XCTAssertEqual(try d.read("pack/keep.txt"),"mine"); XCTAssertEqual(try d.read("pack/same.txt"),"new"); XCTAssertTrue(d.leftovers().isEmpty)
    }
    func testCancellationBeforeCommitAndJournalFailureLeaveNothing() async throws {
        let d = CoreTempDir(), source = try d.file("a.jpg"); var job: ConversionJob!
        let c = converter { step in let output = try self.write(step.output.allocate("png")!,"x"); job.cancel(); return [output] }
        let q = JobQueue(ConverterCatalog([c])); job = ConversionJob([source],corePreset("png"),"Test"); await q.run(job)
        XCTAssertEqual(job.state,.cancelled); XCTAssertEqual(job.files[0].state,.cancelled); XCTAssertFalse(FileManager.default.fileExists(d.path + "/a.png")); XCTAssertTrue(d.leftovers().isEmpty)
        let badJournal = JobQueue(ConverterCatalog([CoreFakeConverter("fake",ConversionEdge("jpg","png"))]),onStaging:{ _ in throw ConversionError("journal failed") })
        let failed = await coreRun(badJournal,[source],corePreset("png")); XCTAssertEqual(failed.files[0].errorDetail,"journal failed"); XCTAssertTrue(d.leftovers().isEmpty)
    }
}
