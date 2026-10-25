import XCTest
@testable import FileToXEngineKit

final class WatchHostTests: XCTestCase {
    func testFailedSaveCannotEnableMonitoringOrAdvanceRevision() async throws {
        let d = CoreTempDir(), store = UserDataStore(d.path + "/core")
        try store.load()
        let pipe = Pipe(), wire = WireWriter(pipe.fileHandleForWriting.fileDescriptor)
        let host = Host(wire, store, [], Localizer("en"), languageFixed: true, onStaging: { _ in })
        let original = store.settings
        var settings = original, rule = WatchRule()
        rule.folder = d.path; rule.presetId = store.presets[0].id; settings.watchFolders = [rule]
        try FileManager.default.createDirectoryIfNeeded(store.directory + "/settings.json")
        XCTAssertThrowsError(try host.handle("save", "settings.save", ["baseRevision": 1, "settings": try WireJson.toNode(settings)]))
        XCTAssertEqual(store.settings, original)
        XCTAssertEqual(hostObject(try host.handle("library", "library.get", [:]))["revision"] as? Int, 1)
        XCTAssertTrue(hostObjects(hostObject(try host.handle("status", "watch.status", [:]))["rules"]).isEmpty)
        await host.cancelAll(1); wire.complete(1)
    }

    func testDisablingQueuedWatchCancelsItAndShutdownStopsMonitoring() async throws {
        let d = CoreTempDir(), started = expectation(description: "blocking conversion started")
        let converter = CoreFakeConverter(edges: [ConversionEdge("txt", "md")]) { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return []
        }
        var preset = corePreset("md"); preset.id = "watch-preset"
        let store = UserDataStore(d.path + "/core"); try store.load(); store.presets.append(preset)
        var rule = WatchRule(); rule.folder = "/private/tmp/ftx-watch-cancel-" + UUID().uuidString; rule.presetId = preset.id; rule.originals = .moveToOriginals
        try FileManager.default.createDirectoryIfNeeded(rule.folder)
        defer { try? FileManager.default.removeItem(atPath: rule.folder) }
        store.settings.watchFolders = [rule]
        let pipe = Pipe(), wire = WireWriter(pipe.fileHandleForWriting.fileDescriptor)
        let host = Host(wire, store, [converter], Localizer("en"), languageFixed: true, onStaging: { _ in })
        let source = try d.file("blocking.txt")
        _ = try host.handle("start", "job.start", ["paths": [source], "presetId": preset.id])
        await fulfillment(of: [started], timeout: 5)
        let watched = rule.folder + "/watched.txt"
        try Data("keep source".utf8).write(to: URL(fileURLWithPath: watched))
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let statuses = hostObject(try host.handle("status", "watch.status", [:]))
            if hostObjects(statuses["rules"]).first?["state"] as? String == "running" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(hostObjects(hostObject(try host.handle("status", "watch.status", [:]))["rules"]).first?["state"] as? String, "running")
        rule.enabled = false
        var settings = store.settings; settings.watchFolders = [rule]
        _ = try host.handle("disable", "settings.save", ["baseRevision": 1, "settings": try WireJson.toNode(settings)])
        await host.cancelAll(5)
        XCTAssertEqual(store.history.count, 2)
        XCTAssertEqual(store.history.first { $0.watchRuleId == rule.id }?.state, .cancelled)
        XCTAssertEqual(try String(contentsOfFile: watched, encoding: .utf8), "keep source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rule.resolvedOutputFolder))
        XCTAssertTrue(d.leftovers().isEmpty)
        wire.complete(2)
    }

    func testSettingsToWatchJobHistoryCollisionAndDisableEndToEnd() throws {
        let d = CoreTempDir(), inbox = d.path + "/inbox"
        try FileManager.default.createDirectoryIfNeeded(inbox)
        let existing = try d.file("inbox/existing.txt", "unchanged")
        let child = try HostChild(d.path); defer { child.close() }
        _ = try child.event("hello")
        var library = try child.call("library.get")
        let presets = library["presets"]!, profiles = library["profiles"]!
        var preset = corePreset("md"); preset.id = "watch-preset"; preset.name = "Watch test"; preset.output.conflict = .rename
        let saved = try child.call("library.save", ["baseRevision": library["revision"]!, "presets": hostObjects(presets) + [hostObject(try WireJson.toNode(preset))], "profiles": profiles])
        var settings = hostObject(saved["settings"]), rule = WatchRule()
        rule.folder = inbox; rule.presetId = preset.id; rule.includeSubfolders = true
        settings["watchFolders"] = [try WireJson.toNode(rule)]
        library = try child.call("settings.save", ["baseRevision": saved["revision"]!, "settings": settings])
        XCTAssertTrue(hostEqual(library["presets"]!, saved["presets"]!)); XCTAssertTrue(hostEqual(library["profiles"]!, profiles))
        XCTAssertEqual(hostObjects(try child.call("watch.status")["rules"]).first?["state"] as? String, "watching")
        let collision = try d.file("inbox/converted/new.md", "preserved collision")
        let source = try d.file("inbox/new.txt", "new input")
        _ = try d.file("inbox/download.txt.part", "partial")
        _ = try d.file("inbox/originals/ignored.txt", "original")
        _ = try d.file("inbox/converted/recursive.txt", "own output")
        let finished = try child.event("job.finished")
        XCTAssertEqual(finished["state"] as? String, "completed")
        let history = hostObject(finished["historyEntry"])
        XCTAssertEqual(history["watchRuleId"] as? String, rule.id)
        XCTAssertEqual(history["sources"] as? [String], [WatchFolderMonitor.canonical(source)])
        let outputs = history["outputs"] as? [String] ?? []
        XCTAssertEqual(outputs.count, 1); XCTAssertNotEqual(outputs.first, collision)
        XCTAssertEqual(try String(contentsOfFile: collision, encoding: .utf8), "preserved collision")
        XCTAssertEqual(try String(contentsOfFile: existing, encoding: .utf8), "unchanged")
        XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "new input")
        XCTAssertEqual(hostObjects(try child.call("history.get")["entries"]).count, 1)
        rule.enabled = false; settings["watchFolders"] = [try WireJson.toNode(rule)]
        _ = try child.call("settings.save", ["baseRevision": library["revision"]!, "settings": settings])
        XCTAssertEqual(hostObjects(try child.call("watch.status")["rules"]).first?["state"] as? String, "disabled")
        let dataBefore = try Data(contentsOf: URL(fileURLWithPath: d.path + "/core/settings.json"))
        child.close()
        let reloaded = UserDataStore(d.path + "/core"); try reloaded.load()
        XCTAssertEqual(reloaded.settings.watchFolders, [rule]); XCTAssertEqual(reloaded.history.first?.watchRuleId, rule.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: d.path + "/core/settings.json")), dataBefore)
        XCTAssertEqual(child.invalid, 0)
    }
}
