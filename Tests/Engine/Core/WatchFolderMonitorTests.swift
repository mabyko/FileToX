import XCTest
import PDFKit
@testable import FileToXEngineKit

final class WatchFolderMonitorTests: XCTestCase {
    func testQueuedAliasRetargetIsRejectedAtAllocationWithoutAnotherScan() async throws {
        let d = CoreTempDir(), monitor = WatchFolderMonitor(), started = expectation(description: "blocking job"), finished = expectation(description: "two jobs finished")
        finished.expectedFulfillmentCount = 2
        var r = rule(d.path + "/inbox"), p = preset
        p.output.fileNamePattern = "victim"; p.output.conflict = .overwrite
        try FileManager.default.createDirectoryIfNeeded(d.path + "/safe")
        r.outputFolder = d.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: r.outputFolder, withDestinationPath: d.path + "/safe")
        let saved = try d.file("inbox/originals/victim.md", "saved original")
        _ = monitor.scan([r], presets: [p], now: 0)
        let source = try d.file("inbox/new.txt", "new input")
        _ = monitor.scan([r], presets: [p], now: 0)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [p], now: 4).first)
        let c = CoreFakeConverter(edges: [ConversionEdge("txt", "md")]) { step in
            if FilePath.fileName(step.inputPath) == "blocker.txt" { started.fulfill(); try await Task.sleep(nanoseconds: 20_000_000_000); return [] }
            guard let path = try step.output.allocate("md") else { return [] }
            try Data("converted".utf8).write(to: URL(fileURLWithPath: path)); return [path]
        }
        let q = JobQueue(ConverterCatalog([c])); q.jobFinished = { _ in finished.fulfill() }
        let first = q.enqueue([try d.file("blocker.txt")], corePreset("md"), "blocker")
        await fulfillment(of: [started], timeout: 2)
        let watched = q.enqueue(batch.files.keys.sorted(), batch.preset, "watch", validateOutput: { try batch.validateOutput($0) })
        try FileManager.default.removeItem(atPath: r.outputFolder)
        try FileManager.default.createSymbolicLink(atPath: r.outputFolder, withDestinationPath: r.originalsFolder)
        first.cancel()
        await fulfillment(of: [finished], timeout: 3); await q.dispose()
        XCTAssertEqual(watched.state, .failed); XCTAssertTrue(watched.outputs.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "saved original")
        XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "new input")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.path + "/safe/victim.md"))
        XCTAssertTrue(d.leftovers().isEmpty)
    }

    func testCommitRechecksRetargetedAliasAndNewlyProtectedOriginalsRoots() async throws {
        for change in ["root", "nested", "retarget"] {
            let d = CoreTempDir(), monitor = WatchFolderMonitor()
            var r = rule(d.path + "/inbox"), p = preset; p.output.fileNamePattern = "victim"; p.output.conflict = .overwrite
            let main = try d.file("inbox/originals/victim.md", "main original"), other = try d.file("other/originals/victim.md", "other original")
            let safe = d.path + "/other/originals"; r.outputFolder = d.path + "/alias"
            try FileManager.default.createSymbolicLink(atPath: r.outputFolder, withDestinationPath: safe)
            _ = monitor.scan([r], presets: [p], now: 0)
            _ = try d.file("inbox/new.txt", "source")
            _ = monitor.scan([r], presets: [p], now: 0)
            let batch = try XCTUnwrap(monitor.scan([r], presets: [p], now: 4).first)
            var currentOriginals: [String] = []
            let c = CoreFakeConverter(edges: [ConversionEdge("txt", "md")]) { step in
                let staged = try XCTUnwrap(step.output.allocate("md"))
                XCTAssertEqual(OutputCommit.finalPath(of: staged), WatchFolderMonitor.canonical(safe) + "/victim.md")
                try Data("overwrite attempt".utf8).write(to: URL(fileURLWithPath: staged))
                if change == "retarget" {
                    try FileManager.default.removeItem(atPath: r.outputFolder)
                    try FileManager.default.createSymbolicLink(atPath: r.outputFolder, withDestinationPath: r.originalsFolder)
                } else { currentOriginals = [safe + (change == "nested" ? "/nested/originals" : "")] }
                return [staged]
            }
            let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "watch", validateOutput: { try batch.validateOutput($0, currentOriginals: currentOriginals) })
            await JobQueue(ConverterCatalog([c])).run(job)
            XCTAssertEqual(job.state, .failed); XCTAssertTrue(job.outputs.isEmpty)
            XCTAssertEqual(try String(contentsOfFile: main, encoding: .utf8), "main original")
            XCTAssertEqual(try String(contentsOfFile: other, encoding: .utf8), "other original")
            XCTAssertTrue(d.leftovers().isEmpty)
        }
    }
    func testActualThreeInputZipAndPdfJobsMoveEverySuccessfulOriginal() async throws {
        for format in ["zip", "pdf"] {
            let d = CoreTempDir(), monitor = WatchFolderMonitor()
            var r = rule(d.path); r.originals = .moveToOriginals
            var p = preset; p.targetFormat = format; p.archive.combineIntoOne = true; p.pdf.mergeIntoSingle = true
            _ = monitor.scan([r], presets: [p], now: 0)
            var sources: [String] = []
            for index in 1...3 {
                let path = format == "pdf" ? try PdfBuilder().newPage().save(d.path + "/\(index).pdf") : try d.file("\(index).txt", "input \(index)")
                sources.append(WatchFolderMonitor.canonical(path))
            }
            let bytes = try sources.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            _ = monitor.scan([r], presets: [p], now: 0)
            let batch = try XCTUnwrap(monitor.scan([r], presets: [p], now: 4).first)
            let queue = JobQueue(ConverterCatalog([]), pdfMerger: PdfSharpConverter(), combiner: ArchiveConverter())
            let job = await coreRun(queue, batch.files.keys.sorted(), batch.preset)
            XCTAssertEqual(job.state, .completed); XCTAssertEqual(job.outputs.count, 1)
            XCTAssertEqual(job.files.first?.outputs.count, 1); XCTAssertTrue(job.files.dropFirst().allSatisfy { $0.outputs.isEmpty && $0.state == .done })
            let output = try XCTUnwrap(job.outputs.first)
            if format == "pdf" { XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: output))?.pageCount, 3) }
            else { XCTAssertEqual(try ZipReader(path: output).entries.map(\.name).sorted(), ["1.txt", "2.txt", "3.txt"]) }
            monitor.complete(batch, job: job, currentRules: [r])
            for (index, source) in sources.enumerated() {
                XCTAssertFalse(FileManager.default.fileExists(atPath: source))
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: r.originalsFolder + "/" + FilePath.fileName(source))), bytes[index])
            }
        }
    }

    func testActualPartialAndFailedMergedJobsKeepFailedInputs() async throws {
        for successful in [Set<Int>(), Set([1, 2]), Set([2, 3])] {
            let d = CoreTempDir(), monitor = WatchFolderMonitor()
            var r = rule(d.path); r.originals = .moveToOriginals
            var p = preset; p.targetFormat = "pdf"; p.pdf.mergeIntoSingle = true
            _ = monitor.scan([r], presets: [p], now: 0)
            var sources: [String] = []
            for index in 1...3 {
                let path = successful.contains(index) ? try PdfBuilder().newPage().save(d.path + "/\(index).pdf") : try d.file("\(index).txt", "keep failed \(index)")
                sources.append(WatchFolderMonitor.canonical(path))
            }
            _ = monitor.scan([r], presets: [p], now: 0)
            let batch = try XCTUnwrap(monitor.scan([r], presets: [p], now: 4).first)
            let job = await coreRun(JobQueue(ConverterCatalog([]), pdfMerger: PdfSharpConverter()), batch.files.keys.sorted(), batch.preset)
            XCTAssertEqual(job.state, successful.isEmpty ? .failed : .completedWithErrors)
            if !successful.isEmpty { XCTAssertEqual(PDFDocument(url: URL(fileURLWithPath: try XCTUnwrap(job.outputs.first)))?.pageCount, successful.count) }
            monitor.complete(batch, job: job, currentRules: [r])
            for (index, source) in sources.enumerated() {
                if successful.contains(index + 1) {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: source))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: r.originalsFolder + "/" + FilePath.fileName(source)))
                } else {
                    XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "keep failed \(index + 1)")
                }
            }
        }
    }

    func testOriginalsOutputOverlapIsRejectedLexicallyAndPhysicallyForLoadedRules() throws {
        let d = CoreTempDir()
        var r = rule(d.path + "/inbox"), p = preset; p.output.conflict = .overwrite
        let saved = try d.file("inbox/originals/victim.md", "saved original")
        _ = try d.file("inbox/new.txt", "source")
        for output in [r.originalsFolder, r.originalsFolder + "/nested", r.folder + "/ORIGINALS"] {
            r.outputFolder = output
            XCTAssertThrowsError(try Validation.watchRule(r))
            XCTAssertTrue(WatchFolderMonitor().scan([r], presets: [p], now: 4).isEmpty)
        }
        let alias = d.path + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: r.originalsFolder)
        r.outputFolder = alias
        XCTAssertThrowsError(try Validation.watchRule(r))
        var aliasSettings = AppSettings(); aliasSettings.watchFolders = [r]
        XCTAssertThrowsError(try Validation.settings(aliasSettings))
        let loaded = WatchFolderMonitor()
        XCTAssertTrue(loaded.scan([r], presets: [p], now: 0).isEmpty)
        XCTAssertTrue(loaded.scan([r], presets: [p], now: 10).isEmpty)
        XCTAssertEqual(loaded.statuses.first?["state"] as? String, "error")
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "saved original")
        var other = rule(d.path + "/other"); other.enabled = false
        r.outputFolder = other.originalsFolder + "/nested"
        var settings = AppSettings(); settings.watchFolders = [r, other]
        XCTAssertThrowsError(try Validation.settings(settings))
        XCTAssertTrue(loaded.scan(settings.watchFolders, presets: [p], now: 20).isEmpty)
    }

    func testEffectiveWatchOutputOverridesPresetFoldersAndSanitizesRenamePatterns() async throws {
        for location in [OutputLocation.default, .customFolder] {
            let d = CoreTempDir(), monitor = WatchFolderMonitor()
            var r = rule(d.path); r.fileNamePattern = "../originals/victim"; r.renames = [.init(kind: .prefix, replace: "../originals/")]
            var p = preset; p.output.location = location; p.output.customFolder = r.originalsFolder; p.output.conflict = .overwrite
            let saved = try d.file("originals/victim.md", "saved original")
            _ = monitor.scan([r], presets: [p], now: 0)
            _ = try d.file("new.txt", "source")
            _ = monitor.scan([r], presets: [p], now: 0)
            let batch = try XCTUnwrap(monitor.scan([r], presets: [p], now: 4).first)
            XCTAssertEqual(batch.preset.output.location, .customFolder); XCTAssertEqual(batch.preset.output.customFolder, WatchFolderMonitor.canonical(r.resolvedOutputFolder))
            let job = await coreRun(JobQueue(ConverterCatalog([CoreFakeConverter("fake", ConversionEdge("txt", "md"))])), batch.files.keys.sorted(), batch.preset)
            XCTAssertEqual(job.state, .completed)
            XCTAssertTrue(job.outputs.allSatisfy { WatchFolderMonitor.contains(WatchFolderMonitor.canonical(r.resolvedOutputFolder), WatchFolderMonitor.canonical($0)) })
            XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "saved original")
        }
    }

    func testSettlingUsesInjectedAwakeMonotonicTime() throws {
        let d = CoreTempDir(); var elapsed = 100.0
        let monitor = WatchFolderMonitor(clock: { elapsed }), r = rule(d.path)
        _ = monitor.scan([r], presets: [preset])
        _ = try d.file("new.txt")
        _ = monitor.scan([r], presets: [preset])
        XCTAssertTrue(monitor.scan([r], presets: [preset]).isEmpty)
        elapsed += 2.9; XCTAssertTrue(monitor.scan([r], presets: [preset]).isEmpty)
        elapsed += 0.1; XCTAssertEqual(monitor.scan([r], presets: [preset]).first?.files.count, 1)
    }
    func testMetadataOnlyChangesDoNotTriggerAndFutureModificationTimesSettle() throws {
        let d = CoreTempDir(), now = 100.0, r = rule(d.path)
        let source = try d.file("source.txt"), future = try d.file("future.txt")
        let stamp = try XCTUnwrap(WatchFolderMonitor.Stamp.read(source))
        let futureStamp = WatchFolderMonitor.Stamp(device: stamp.device, inode: stamp.inode + 1, size: 1, modified: timespec(tv_sec: Int(Date().timeIntervalSince1970) + 86400, tv_nsec: 0), changed: stamp.changed)
        var files = [source: stamp]
        let monitor = WatchFolderMonitor(reader: { _, _, _ in .init(identity: .init(device: 1, inode: 1), files: files) })
        _ = monitor.scan([r], presets: [preset], now: now)
        files[source] = .init(device: stamp.device, inode: stamp.inode, size: stamp.size, modified: stamp.modified, changed: timespec(tv_sec: stamp.changed.tv_sec + 1, tv_nsec: 0))
        files[future] = futureStamp
        _ = monitor.scan([r], presets: [preset], now: now)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (4)).first)
        XCTAssertEqual(batch.files.keys.sorted(), [future])
        XCTAssertNil(batch.files[source])
    }

    func testChangedRootIdentityRebaselinesWithoutClaimingPhysicalRemount() throws {
        let d = CoreTempDir(), now = 100.0, r = rule(d.path)
        var identity = WatchFolderMonitor.RootIdentity(device: 1, inode: 1), files: [String: WatchFolderMonitor.Stamp] = [:]
        let monitor = WatchFolderMonitor(reader: { _, _, _ in .init(identity: identity, files: files) })
        _ = monitor.scan([r], presets: [preset], now: now)
        let existing = try d.file("mounted-existing.txt")
        files[existing] = try XCTUnwrap(WatchFolderMonitor.Stamp.read(existing))
        identity = .init(device: 2, inode: 1)
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now).isEmpty)
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now + (4)).isEmpty)
        let added = try d.file("new-after-mount.txt")
        files[added] = try XCTUnwrap(WatchFolderMonitor.Stamp.read(added))
        _ = monitor.scan([r], presets: [preset], now: now + (5))
        XCTAssertEqual(monitor.scan([r], presets: [preset], now: now + (9)).first?.files.keys.sorted(), [added])
    }

    func testBatchesAreBoundedPendingFilesDrainAndDiscardReleasesActivePaths() throws {
        let d = CoreTempDir(), now = 100.0, r = rule(d.path)
        let stamp = try XCTUnwrap(WatchFolderMonitor.Stamp.read(try d.file("stamp.txt")))
        var files: [String: WatchFolderMonitor.Stamp] = [:]
        let monitor = WatchFolderMonitor(reader: { _, _, _ in .init(identity: .init(device: 1, inode: 1), files: files) })
        _ = monitor.scan([r], presets: [preset], now: now)
        for index in 0..<300 { files[d.path + "/\(index).txt"] = stamp }
        _ = monitor.scan([r], presets: [preset], now: now)
        let first = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (4)).first)
        XCTAssertEqual(first.files.count, 128)
        monitor.discard([first])
        let retry = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (5)).first)
        XCTAssertEqual(Set(first.files.keys), Set(retry.files.keys))
        var processed = Set(retry.files.keys)
        for offset in 6...7 {
            let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (Double(offset))).first)
            XCTAssertLessThanOrEqual(batch.files.count, 128)
            XCTAssertTrue(processed.isDisjoint(with: batch.files.keys))
            processed.formUnion(batch.files.keys)
        }
        XCTAssertEqual(processed.count, 300)
    }

    func testPackageAndDownloadRootsAndContentsAreNeverConvertedOrMoved() throws {
        let d = CoreTempDir(), now = 100.0, monitor = WatchFolderMonitor()
        var r = rule(d.path); r.originals = .moveToOriginals
        _ = monitor.scan([r], presets: [preset], now: now)
        let package = try d.file("document.rtfd/TXT.rtf", "package contents")
        let downloading = try d.file("partial.download/document.txt", "partial contents")
        let source = try d.file("ready.txt")
        _ = monitor.scan([r], presets: [preset], now: now)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (4)).first)
        XCTAssertEqual(batch.files.keys.sorted(), [WatchFolderMonitor.canonical(source)])
        let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "Watch")
        job.files[0].state = .done; job.files[0].outputs = [try d.file("converted/ready.md")]
        monitor.complete(batch, job: job, currentRules: [r])
        XCTAssertEqual(try String(contentsOfFile: package, encoding: .utf8), "package contents")
        XCTAssertEqual(try String(contentsOfFile: downloading, encoding: .utf8), "partial contents")
        for folder in ["document.rtfd", "partial.download"] {
            r.folder = d.path + "/" + folder
            XCTAssertTrue(WatchFolderMonitor().scan([r], presets: [preset], now: now).isEmpty)
        }
    }

    func testUppercaseOriginalsDirectoryUsesPhysicalParentAndExclusiveRename() throws {
        let d = CoreTempDir(), now = 100.0, monitor = WatchFolderMonitor()
        var r = rule(d.path); r.originals = .moveToOriginals
        let collision = try d.file("ORIGINALS/photo.txt", "keep collision")
        guard FileManager.default.fileExists(atPath: r.originalsFolder) else { throw XCTSkip("Case-insensitive filesystem required for uppercase alias regression.") }
        _ = monitor.scan([r], presets: [preset], now: now)
        let source = try d.file("photo.txt", "new input")
        _ = monitor.scan([r], presets: [preset], now: now)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (4)).first)
        let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "Watch")
        job.files[0].state = .done; job.files[0].outputs = [try d.file("converted/photo.md")]
        monitor.complete(batch, job: job, currentRules: [r])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
        XCTAssertEqual(try String(contentsOfFile: collision, encoding: .utf8), "keep collision")
        XCTAssertEqual(try d.read("ORIGINALS/2-photo.txt"), "new input")
    }
    private func rule(_ folder: String) -> WatchRule {
        var rule = WatchRule(); rule.folder = folder; rule.presetId = "watch-preset"; rule.includeSubfolders = true
        return rule
    }
    private var preset: Preset { var p = corePreset("md"); p.id = "watch-preset"; return p }

    func testBaselineSettlingChangedFilesAndInFlightDeduplication() throws {
        let d = CoreTempDir(), monitor = WatchFolderMonitor(), r = rule(d.path), now = 100.0
        let existing = try d.file("existing.txt")
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now).isEmpty)
        let source = try d.file("new.txt")
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now).isEmpty)
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now + (2)).isEmpty)
        try Data("still writing".utf8).write(to: URL(fileURLWithPath: source))
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now + (3)).isEmpty)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (7)).first)
        XCTAssertEqual(Array(batch.files.keys), [WatchFolderMonitor.canonical(source)]); XCTAssertNil(batch.files[WatchFolderMonitor.canonical(existing)])
        XCTAssertEqual(batch.preset.output.customFolder, WatchFolderMonitor.canonical(r.resolvedOutputFolder))
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now + (20)).isEmpty)
        let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "Watch")
        monitor.complete(batch, job: job, currentRules: [r])
        XCTAssertTrue(monitor.scan([r], presets: [preset], now: now + (30)).isEmpty)
        try Data("changed existing".utf8).write(to: URL(fileURLWithPath: existing))
        _ = monitor.scan([r], presets: [preset], now: now + (31))
        XCTAssertEqual(monitor.scan([r], presets: [preset], now: now + (35)).first?.files.keys.sorted(), [WatchFolderMonitor.canonical(existing)])
    }

    func testOutputOriginalsTemporarySymlinksAndSubfolderFilters() throws {
        let d = CoreTempDir(), outside = CoreTempDir(), monitor = WatchFolderMonitor(), now = 100.0
        var r = rule(d.path); r.include = ["*.txt"]
        _ = monitor.scan([r], presets: [preset], now: now)
        for name in ["converted/out.txt", "originals/old.txt", ".hidden.txt", "download.txt.part", "not-included.md", "doc.rtfd/TXT.rtf", "nested.rtfd/data.txt", "incoming.download/data.txt", "incoming.tmp/data.txt", "Example.app/Contents/data.txt"] { _ = try d.file(name) }
        let nested = try d.file("sub/new.txt"), direct = try d.file("new.txt"), target = try outside.file("outside.txt")
        try FileManager.default.createSymbolicLink(atPath: d.path + "/linked.txt", withDestinationPath: target)
        try FileManager.default.createSymbolicLink(atPath: d.path + "/linked-folder", withDestinationPath: outside.path)
        _ = monitor.scan([r], presets: [preset], now: now)
        XCTAssertEqual(monitor.scan([r], presets: [preset], now: now + (4)).first?.files.keys.sorted(), [direct, nested].map(WatchFolderMonitor.canonical).sorted())
        let flat = WatchFolderMonitor(); r.includeSubfolders = false
        _ = flat.scan([r], presets: [preset], now: now)
        _ = try d.file("sub/later.txt"); let later = try d.file("later.txt")
        _ = flat.scan([r], presets: [preset], now: now)
        XCTAssertEqual(flat.scan([r], presets: [preset], now: now + (4)).first?.files.keys.sorted(), [WatchFolderMonitor.canonical(later)])
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
        let d = CoreTempDir(), monitor = WatchFolderMonitor(), now = 100.0
        var r = rule(d.path); r.originals = .moveToOriginals
        _ = monitor.scan([r], presets: [preset], now: now)
        let source = try d.file("photo.txt"), changed = try d.file("changed.txt"), failed = try d.file("failed.txt")
        _ = monitor.scan([r], presets: [preset], now: now)
        let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (4)).first)
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
            let d = CoreTempDir(), monitor = WatchFolderMonitor(), now = 100.0
            var r = rule(d.path); r.originals = .moveToOriginals
            _ = monitor.scan([r], presets: [preset], now: now)
            let source = try d.file("input.txt")
            _ = monitor.scan([r], presets: [preset], now: now)
            let batch = try XCTUnwrap(monitor.scan([r], presets: [preset], now: now + (4)).first)
            let job = ConversionJob(batch.files.keys.sorted(), batch.preset, "Watch")
            job.files[0].state = .done; job.files[0].outputs = [try d.file("converted/output.md")]
            if cancel { job.cancel() } else { r.enabled = false }
            monitor.complete(batch, job: job, currentRules: [r])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        }
    }
}
