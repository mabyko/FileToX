import XCTest
@testable import FileToXEngineKit

final class WatchFolderMonitorTests: XCTestCase {
    private func rule(_ folder: String) -> WatchRule {
        var rule = WatchRule(); rule.folder = folder; rule.presetId = "watch-preset"; rule.includeSubfolders = true
        return rule
    }
    private var preset: Preset { var p = corePreset("md"); p.id = "watch-preset"; return p }

    func testBaselineSettlingChangedFilesAndInFlightDeduplication() throws {
        let d = CoreTempDir(), monitor = WatchFolderMonitor(), r = rule(d.path), now = Date().addingTimeInterval(10)
        let existing = try d.file("existing.txt")
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now).isEmpty)
        let source = try d.file("new.txt")
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now).isEmpty)
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(2)).isEmpty)
        try Data("still writing".utf8).write(to: URL(fileURLWithPath: source))
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(3)).isEmpty)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(7)).first)
        XCTAssertEqual(Array(batch.files.keys), [WatchFolderMonitor.canonical(source)]); XCTAssertNil(batch.files[WatchFolderMonitor.canonical(existing)])
        XCTAssertEqual(batch.preset.output.customFolder, r.resolvedOutputFolder)
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(20)).isEmpty)
        let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "Watch")
        monitor.complete(batch, job: job, currentRules: [r])
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(30)).isEmpty)
        try Data("changed existing".utf8).write(to: URL(fileURLWithPath: existing))
        _ = monitor.scan([r], presets: [preset], now: now.addingTimeInterval(31))
        XCTAssertEqual(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(35)).first?.files.keys.sorted(), [WatchFolderMonitor.canonical(existing)])
    }

    func testOutputOriginalsTemporarySymlinksAndSubfolderFilters() throws {
        let d = CoreTempDir(), outside = CoreTempDir(), monitor = WatchFolderMonitor(), now = Date().addingTimeInterval(10)
        var r = rule(d.path); r.include = ["*.txt"]
        _ = monitor.scan([r], presets: [preset], now: now)
        for name in ["converted/out.txt", "originals/old.txt", ".hidden.txt", "download.txt.part", "not-included.md"] { _ = try d.file(name) }
        let nested = try d.file("sub/new.txt"), direct = try d.file("new.txt"), target = try outside.file("outside.txt")
        try FileManager.default.createSymbolicLink(atPath: d.path + "/linked.txt", withDestinationPath: target)
        try FileManager.default.createSymbolicLink(atPath: d.path + "/linked-folder", withDestinationPath: outside.path)
        _ = monitor.scan([r], presets: [preset], now: now)
        XCTAssertEqual(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(4)).first?.files.keys.sorted(), [direct, nested].map(WatchFolderMonitor.canonical).sorted())
        let flat = WatchFolderMonitor(); r.includeSubfolders = false
        _ = flat.scan([r], presets: [preset], now: now)
        _ = try d.file("sub/later.txt"); let later = try d.file("later.txt")
        _ = flat.scan([r], presets: [preset], now: now)
        XCTAssertEqual(flat.scan([r], presets: [preset], now: now.addingTimeInterval(4)).first?.files.keys.sorted(), [WatchFolderMonitor.canonical(later)])
    }

    func testValidationAndUnavailableStatusDoNotProcessInvalidRules() throws {
        let d = CoreTempDir(), monitor = WatchFolderMonitor()
        var r = rule(d.path); r.outputFolder = d.path
        XCTAssertThrowsError(try Validation.watchRule(r))
        r.outputFolder = URL(fileURLWithPath: d.path).deletingLastPathComponent().path
        XCTAssertThrowsError(try Validation.watchRule(r))
        r.outputFolder = ""; r.include = ["/broken(/"]
        XCTAssertThrowsError(try Validation.watchRule(r))
        r.include = []; r.presetId = "missing"
        XCTAssertTrue(monitor.scan([r], presets: [preset]).isEmpty)
        XCTAssertEqual(monitor.statuses.first?["state"] as? String, "error")
        r.enabled = false
        XCTAssertTrue(monitor.scan([r], presets: [preset]).isEmpty)
        XCTAssertEqual(monitor.statuses.first?["state"] as? String, "disabled")
        r.enabled = true; r.presetId = preset.id; r.folder += "/missing"
        _ = monitor.scan([r], presets: [preset])
        XCTAssertEqual(monitor.statuses.first?["state"] as? String, "error")
        var settings = AppSettings(); settings.watchFolders = [r, r]
        XCTAssertThrowsError(try Validation.settings(settings))
    }

    func testMoveOriginalsOnlyAfterCommittedSuccessWithoutReplacingCollisions() throws {
        let d = CoreTempDir(), monitor = WatchFolderMonitor(), now = Date().addingTimeInterval(10)
        var r = rule(d.path); r.originals = .moveToOriginals
        _ = monitor.scan([r], presets: [preset], now: now)
        let source = try d.file("photo.txt"), changed = try d.file("changed.txt"), failed = try d.file("failed.txt")
        _ = monitor.scan([r], presets: [preset], now: now)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(4)).first)
        let original = try d.file("originals/photo.txt", "preserve")
        let output = try d.file("converted/photo.md", "committed")
        let job = ConversionJob([source, changed, failed].map(WatchFolderMonitor.canonical), batch.preset, "Watch")
        for file in job.files { file.state = file.sourcePath == WatchFolderMonitor.canonical(failed) ? .failed : .done; file.outputs = file.state == .done ? [output] : [] }
        try Data("changed during conversion".utf8).write(to: URL(fileURLWithPath: changed))
        monitor.complete(batch, job: job, currentRules: [r])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.path + "/originals/2-photo.txt"))
        XCTAssertEqual(try String(contentsOfFile: original, encoding: .utf8), "preserve")
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed)); XCTAssertTrue(FileManager.default.fileExists(atPath: failed))
    }

    func testCancelledAndDisabledJobsNeverMoveSources() throws {
        for cancel in [false, true] {
            let d = CoreTempDir(), monitor = WatchFolderMonitor(), now = Date().addingTimeInterval(10)
            var r = rule(d.path); r.originals = .moveToOriginals
            _ = monitor.scan([r], presets: [preset], now: now)
            let source = try d.file("input.txt")
            _ = monitor.scan([r], presets: [preset], now: now)
            let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now.addingTimeInterval(4)).first)
            let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "Watch")
            job.files[0].state = .done; job.files[0].outputs = [try d.file("converted/output.md")]
            if cancel { job.cancel() } else { r.enabled = false }
            monitor.complete(batch, job: job, currentRules: [r])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        }
    }
}
