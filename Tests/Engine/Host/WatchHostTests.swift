import XCTest
@testable import FileToXEngineKit

final class WatchHostTests: XCTestCase {
    func testBlockedScanKeepsHelloStatusSettingsProgressAndCancelResponsiveAndDropsStaleResults() async throws {
        for stop in [false, true] {
            let d = CoreTempDir(), entered = expectation(description: "scanner blocked"), replied = expectation(description: "RPCs returned")
            let staleJob = expectation(description: "stale watch batch must not run"); staleJob.isInverted = true
            let release = DispatchSemaphore(value: 0), lock = NSLock()
            var block = false, files: [String: WatchFolderMonitor.Stamp] = [:]
            let monitor = WatchFolderMonitor(reader: { _, _, _ in
                let snapshot = lock.withLock { (block, files) }
                if snapshot.0 {
                    entered.fulfill(); _ = release.wait(timeout: .now() + 8)
                    lock.withLock { block = false }
                }
                return .init(identity: .init(device: 1, inode: 1), files: snapshot.1)
            })
            defer { release.signal() }
            var preset = corePreset("md"); preset.id = "watch-preset"
            let store = UserDataStore(d.path + "/core"); try store.load(); store.presets.append(preset)
            var rule = WatchRule(); rule.folder = d.path + "/inbox"; rule.presetId = preset.id
            store.settings.watchFolders = [rule]
            _ = monitor.scan([rule], presets: store.presets, now: Date().addingTimeInterval(-10))
            let watched = try d.file("inbox/watched.txt")
            files[watched] = try XCTUnwrap(WatchFolderMonitor.Stamp.read(watched))
            _ = monitor.scan([rule], presets: store.presets, now: Date().addingTimeInterval(-10))
            block = true
            let converter = CoreFakeConverter(edges: [ConversionEdge("txt", "md")]) { step in
                if step.inputPath == watched { staleJob.fulfill() }
                try await Task.sleep(nanoseconds: 20_000_000_000); return []
            }
            let log = try d.file("wire.jsonl", ""), output = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
            defer { try? output.close() }
            let wire = WireWriter(output.fileDescriptor)
            let constructedAt = Date()
            let host = Host(wire, store, [converter], Localizer("en"), languageFixed: true, watcher: monitor, onStaging: { _ in })
            XCTAssertLessThan(Date().timeIntervalSince(constructedAt), 1, "Host construction must not wait for the scanner")
            wire.event("hello", ["protocol": 1]); host.startWatching()
            await fulfillment(of: [entered], timeout: 2)
            let source = try d.file("manual.txt")
            DispatchQueue.global().async {
                do {
                    XCTAssertEqual(hostObjects(hostObject(try host.handle("status", "watch.status", [:]))["rules"]).first?["state"] as? String, "starting")
                    if stop { _ = try host.handle("stop", "watch.stop", [:]) } else { rule.enabled = false }
                    var settings = store.settings; settings.watchFolders = [rule]
                    _ = try host.handle("settings", "settings.save", ["baseRevision": 1, "settings": try WireJson.toNode(settings)])
                    _ = try host.handle("manual", "job.start", ["paths": [source], "presetId": preset.id])
                    Thread.sleep(forTimeInterval: 0.25)
                    let messages = Self.messages(log)
                    XCTAssertEqual(messages.first?["event"] as? String, "hello")
                    XCTAssertTrue(messages.contains { $0["event"] as? String == "job.updated" })
                    let id = try XCTUnwrap(hostObject(messages.first { $0["id"] as? String == "manual" }?["result"])["jobId"] as? String)
                    _ = try host.handle("cancel", "job.cancel", ["jobId": id])
                } catch { XCTFail("RPC failed: \(error)") }
                replied.fulfill()
            }
            await fulfillment(of: [replied], timeout: 2)
            let deadline = Date().addingTimeInterval(2)
            while !Self.messages(log).contains(where: { $0["event"] as? String == "job.finished" }), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(Self.messages(log).contains { $0["event"] as? String == "job.finished" }, "Cancellation must finish while scan stays blocked")
            release.signal()
            await fulfillment(of: [staleJob], timeout: 0.5)
            XCTAssertEqual(hostObjects(hostObject(try host.handle("final", "watch.status", [:]))["rules"]).first?["state"] as? String, stop ? "stopped" : "disabled")
            XCTAssertEqual(store.history.count, 1)
            XCTAssertEqual(try String(contentsOfFile: watched, encoding: .utf8), "x")
            await host.cancelAll(1); wire.complete(1)
        }
    }

    private static func messages(_ path: String) -> [[String: Any]] {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return bytes.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

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
        host.startWatching()
        try await waitForWatch(host, state: "watching")
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
        rule.folder = inbox; rule.presetId = preset.id; rule.includeSubfolders = true; rule.include = [".TXT"]
        settings["watchFolders"] = [try WireJson.toNode(rule)]
        library = try child.call("settings.save", ["baseRevision": saved["revision"]!, "settings": settings])
        XCTAssertEqual(hostObjects(hostObject(library["settings"])["watchFolders"]).first?["include"] as? [String], ["*.txt"])
        rule.include = ["*.txt"]
        XCTAssertTrue(hostEqual(library["presets"]!, saved["presets"]!)); XCTAssertTrue(hostEqual(library["profiles"]!, profiles))
        try waitForWatch(child, state: "watching")
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
        _ = try child.call("watch.stop")
        XCTAssertEqual(hostObjects(try child.call("watch.status")["rules"]).first?["state"] as? String, "stopped")
        let dataBefore = try Data(contentsOf: URL(fileURLWithPath: d.path + "/core/settings.json"))
        child.close()
        let reloaded = UserDataStore(d.path + "/core"); try reloaded.load()
        XCTAssertEqual(reloaded.settings.watchFolders, [rule]); XCTAssertEqual(reloaded.history.first?.watchRuleId, rule.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: d.path + "/core/settings.json")), dataBefore)
        XCTAssertEqual(child.invalid, 0)
    }
    private func waitForWatch(_ host: FileToXEngineKit.Host, state: String) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if hostObjects(hostObject(try host.handle("state", "watch.status", [:]))["rules"]).first?["state"] as? String == state { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Watch status did not become \(state)")
    }
    private func waitForWatch(_ child: HostChild, state: String) throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if hostObjects(try child.call("watch.status")["rules"]).first?["state"] as? String == state { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Watch status did not become \(state)")
    }

}
