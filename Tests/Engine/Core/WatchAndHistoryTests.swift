import XCTest
@testable import FileToXEngineKit

final class WatchRuleOptionsTests: XCTestCase {
    func testPatternsNormalizationValidationAndAnyMatch() {
        for (pattern,name,expected) in [("*.heic","IMG_0001.HEIC",true),("*.heic","IMG_0001.jpg",false),("scan_??.png","scan_12.png",true),("scan_??.png","scan_123.png",false),(#"/^IMG_\d+\.jpg$/"#,"img_20261011.jpg",true),(#"/^IMG_\d+\.jpg$/"#,"IMG_cat.jpg",false),(#"/^report-\d{2,4}/"#,"report-2026 final.docx",true)] { XCTAssertNil(FileNameFilter.validate(pattern)); XCTAssertEqual(FileNameFilter.of([pattern]).matches(name),expected) }
        let filter = FileNameFilter.of(["*.heic","scan_*"])
        XCTAssertTrue(filter.matches("scan_0412.pdf")); XCTAssertTrue(filter.matches("a.heic")); XCTAssertFalse(filter.matches("notes.txt")); XCTAssertTrue(FileNameFilter.of([]).matches("anything.pdf"))
        for (typed,expected) in [("heic","*.heic"),(".HEIC","*.heic"),("scan","*scan*"),("scan_*","scan_*"),(#"/^IMG_\d+/"#,#"/^IMG_\d+/"#)] { XCTAssertEqual(FileNameFilter.normalize(typed),expected) }
        XCTAssertNil(FileNameFilter.normalize("  ")); XCTAssertNotNil(FileNameFilter.validate("/IMG_(/")); XCTAssertTrue(FileNameFilter.of(["/IMG_(/"]).matches("anything.jpg"))
    }
    func testWatchRuleApplyAndCopy() {
        var preset = corePreset("pdf"); preset.output.fileNamePattern = "{name}_{preset}"
        var rule = WatchRule(); rule.folder = "/x/Inbox"
        let plain = rule.apply(preset)
        XCTAssertEqual(plain.output.fileNamePattern,"{name}_{preset}"); XCTAssertEqual(plain.output.location,.customFolder); XCTAssertEqual(plain.output.customFolder,"/x/Inbox/converted")
        rule.fileNamePattern = " {name}_{date} "; rule.renames = [.init(kind:.regex,find:#"IMG_(\d+)"#,replace:"Photo_$1"),.init(find:"",replace:"typing")]
        let own = rule.apply(preset)
        XCTAssertEqual(own.output.fileNamePattern,"{name}_{date}"); XCTAssertEqual(own.output.renames.count,1); XCTAssertTrue(preset.output.renames.isEmpty)
        XCTAssertEqual(rule.originalsFolder,"/x/Inbox/originals")
    }
}
final class HistoryEntryTests: XCTestCase {
    func testFailurePresetAndSuccessPersist() async throws {
        let d = CoreTempDir(), q = JobQueue(ConverterCatalog([CoreFakeConverter("magick",ConversionEdge("jpg","png"))]))
        let p = corePreset("png") { $0.output.location = .customFolder; $0.output.customFolder = d.path + "/out" }
        let sources = [try d.file("photo.jpg"),try d.file("notes.xyz")]
        let job = await coreRun(q,sources,p), store = UserDataStore(d.path)
        try store.load(); try store.addHistory(HistoryEntry.from(job))
        let reloaded = UserDataStore(d.path); try reloaded.load()
        let entry = try XCTUnwrap(reloaded.history.first)
        XCTAssertEqual(entry.state,.completedWithErrors); XCTAssertEqual(entry.failures.first?.source,sources[1]); XCTAssertEqual(entry.failures.first?.errorKey,"error.unsupported_source"); XCTAssertEqual(entry.preset?.output.customFolder,d.path + "/out"); XCTAssertEqual(entry.outputs,job.outputs)
        let success = await coreRun(q,[sources[0]],p); XCTAssertNil(HistoryEntry.from(success).preset)
    }
    func testWatchResultsNewestAttemptWinsAndUnixPathsStayDistinct() {
        var a = HistoryEntry(); a.watchRuleId = "inbox"; a.sources = ["a.jpg"]
        var other = HistoryEntry(); other.watchRuleId = "other"; other.sources = ["x.jpg"]
        var old = HistoryEntry(); old.watchRuleId = "inbox"; old.sources = ["a.jpg","b.jpg","c.jpg"]; old.preset = corePreset("pdf")
        old.failures = ["a.jpg","b.jpg"].map { var f = HistoryFailure(); f.source = $0; return f }
        let results = WatchResults.of([a,other,old],"inbox")
        XCTAssertEqual(results.converted,2); XCTAssertEqual(results.failures.first?.failure.source,"b.jpg"); XCTAssertEqual(results.failures.first?.preset,old.preset); XCTAssertTrue(WatchResults.of([a],"nothing").isEmpty)
        a.sources = ["a.jpg","A.jpg"]; XCTAssertEqual(WatchResults.of([a],"inbox").converted,2)
    }
}
