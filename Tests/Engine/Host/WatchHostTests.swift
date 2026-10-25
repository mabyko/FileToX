import XCTest
@testable import FileToXEngineKit

final class WatchHostTests: XCTestCase {
    func testHistoricalBatchFailureDoesNotCancelHealthyQueuedBatchForSameRule() async throws {
        let d = CoreTempDir(), lock = NSLock()
        let observedA = expectation(description: "A observed"), observedB = expectation(description: "B observed")
        let startedA = expectation(description: "A running"), startedB = expectation(description: "B running")
        var elapsed = 0.0, files: [String: WatchFolderMonitor.Stamp] = [:]
        var sawA = false, sawB = false, failA = false, finishB = false
        let store = UserDataStore(d.path + "/core"); try store.load()
        var preset = corePreset("md"); preset.id = "watch-preset"; store.presets.append(preset)
        var rule = WatchRule(); rule.folder = d.path + "/inbox"; rule.presetId = preset.id
        try FileManager.default.createDirectoryIfNeeded(rule.folder)
        let a = WatchFolderMonitor.canonical(rule.folder) + "/a.txt", b = WatchFolderMonitor.canonical(rule.folder) + "/b.txt"
        store.settings.watchFolders = [rule]
        let monitor = WatchFolderMonitor(clock: { lock.withLock { elapsed } }, reader: { _, _, _ in
            let snapshot = lock.withLock { () -> ([String: WatchFolderMonitor.Stamp], Bool, Bool) in
                let notifyA = files[a] != nil && !sawA, notifyB = files[b] != nil && !sawB
                sawA = sawA || notifyA; sawB = sawB || notifyB
                return (files, notifyA, notifyB)
            }
            if snapshot.1 { observedA.fulfill() }; if snapshot.2 { observedB.fulfill() }
            return .init(identity: .init(device: 1, inode: 1), files: snapshot.0)
        })
        let converter = CoreFakeConverter(edges: [ConversionEdge("txt", "md")]) { step in
            if step.inputPath == a {
                startedA.fulfill()
                while !lock.withLock({ failA }) { try await Task.sleep(nanoseconds: 10_000_000) }
                throw ConversionError("batch A conversion failed")
            }
            XCTAssertEqual(step.inputPath, b); startedB.fulfill()
            while !lock.withLock({ finishB }) { try await Task.sleep(nanoseconds: 10_000_000) }
            try Task.checkCancellation()
            guard let output = try step.output.allocate("md") else { return [] }
            try Data("healthy B output".utf8).write(to: URL(fileURLWithPath: output)); return [output]
        }
        let log = try d.file("wire.jsonl", ""), output = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        defer { try? output.close() }
        let wire = WireWriter(output.fileDescriptor)
        let host = Host(wire, store, [converter], Localizer("en"), languageFixed: true, watcher: monitor, onStaging: { _ in })
        host.startWatching(); try await waitForWatch(host, state: "watching")
        try Data("source A".utf8).write(to: URL(fileURLWithPath: a))
        let stampA = try XCTUnwrap(WatchFolderMonitor.Stamp.read(a)); lock.withLock { files[a] = stampA }
        await fulfillment(of: [observedA], timeout: 3)
        lock.withLock { elapsed = 4 }
        await fulfillment(of: [startedA], timeout: 3)
        try Data("source B".utf8).write(to: URL(fileURLWithPath: b))
        let stampB = try XCTUnwrap(WatchFolderMonitor.Stamp.read(b)); lock.withLock { files[b] = stampB }
        await fulfillment(of: [observedB], timeout: 3)
        lock.withLock { elapsed = 8 }
        func queuedB() -> Bool {
            Self.messages(log).contains {
                let data = hostObject($0["data"])
                return $0["event"] as? String == "job.updated" && data["state"] as? String == "queued" && hostObjects(data["files"]).contains { $0["source"] as? String == b }
            }
        }
        let queuedDeadline = Date().addingTimeInterval(3)
        while !queuedB(), Date() < queuedDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(queuedB(), "B must be a separate queued batch before A fails")
        lock.withLock { failA = true }
        await fulfillment(of: [startedB], timeout: 3)
        try await waitForWatch(host, state: "error")
        let status = hostObjects(hostObject(try host.handle("error", "watch.status", [:]))["rules"]).first
        XCTAssertTrue((status?["detail"] as? String)?.contains("batch A conversion failed") == true, "Historical failure must remain visible while B runs")
        lock.withLock { finishB = true }
        var historyB: [String: Any]?
        let finishedDeadline = Date().addingTimeInterval(3)
        while Date() < finishedDeadline {
            let entries = hostObjects(hostObject(try host.handle("history", "history.get", [:]))["entries"])
            historyB = entries.first { ($0["sources"] as? [String]) == [b] }
            if historyB != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(historyB?["state"] as? String, "completed")
        if historyB?["state"] as? String == "completed" { XCTAssertEqual(try d.read("inbox/converted/b.md"), "healthy B output") }
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), "source A")
        XCTAssertEqual(try String(contentsOfFile: b, encoding: .utf8), "source B")
        await host.cancelAll(2); wire.complete(1)
        XCTAssertEqual(store.history.count, 2)
    }

    func testBlockedCommitAndFinishedOutputKindDoNotBlockStatusStopSettingsOrCancel() async throws {
        for blockKind in [false, true] {
            let d = CoreTempDir(), blocked = expectation(description: blockKind ? "output kind blocked" : "commit blocked"), responded = expectation(description: "RPCs responsive")
            let release = DispatchSemaphore(value: 0), lock = NSLock(); var once = false
            func pause() {
                let wait = lock.withLock { () -> Bool in if once { return false }; once = true; return true }
                if wait { blocked.fulfill(); _ = release.wait(timeout: .now() + 8) }
            }
            defer { release.signal() }
            let store = UserDataStore(d.path + "/core"); try store.load()
            let log = try d.file("wire.jsonl", ""), output = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
            defer { try? output.close() }
            let wire = WireWriter(output.fileDescriptor)
            let host = Host(wire, store, [CoreFakeConverter("fake", ConversionEdge("txt", "md"))], Localizer("en"), languageFixed: true,
                            beforeOutputCommit: { _ in if !blockKind { pause() } }, outputIsDirectory: { _ in if blockKind { pause() }; return false }, onStaging: { _ in })
            let source = try d.file("source.txt", "keep source")
            _ = try host.handle("first", "job.start", ["paths": [source], "targetFormat": "md"])
            await fulfillment(of: [blocked], timeout: 2)
            try await Task.sleep(nanoseconds: 200_000_000)
            DispatchQueue.global().async {
                do {
                    _ = try host.handle("status", "watch.status", [:])
                    _ = try host.handle("settings", "settings.save", ["baseRevision": 1, "settings": try WireJson.toNode(store.settings)])
                    let id = try XCTUnwrap(hostObject(Self.messages(log).first { $0["id"] as? String == "first" }?["result"])["jobId"] as? String)
                    _ = try host.handle("cancel", "job.cancel", ["jobId": id])
                    _ = try host.handle("stop", "watch.stop", [:])
                    _ = try host.handle("library", "library.get", [:])
                } catch { XCTFail("RPC failed while output I/O was blocked: \(error)") }
                responded.fulfill()
            }
            await fulfillment(of: [responded], timeout: 1)
            XCTAssertTrue(Self.messages(log).contains { $0["event"] as? String == "job.updated" }, "Progress must flush while output I/O is blocked")
            release.signal(); await host.cancelAll(3); wire.complete(1)
            let entries = store.history
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.outputs.count, blockKind ? 1 : 0)
            XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "keep source")
            XCTAssertTrue(d.leftovers().isEmpty)
        }
    }

    func testPhysicalValidationErrorCancelsAlreadyQueuedWatchWork() async throws {
        let d = CoreTempDir(), started = expectation(description: "manual queue blocker")
        let store = UserDataStore(d.path + "/core"); try store.load()
        var preset = corePreset("md"); preset.id = "watch-preset"; preset.output.fileNamePattern = "victim"; preset.output.conflict = .overwrite
        store.presets.append(preset)
        var rule = WatchRule(); rule.folder = d.path + "/inbox"; rule.presetId = preset.id; rule.outputFolder = d.path + "/alias"
        let saved = try d.file("inbox/originals/victim.md", "saved original")
        try FileManager.default.createDirectoryIfNeeded(d.path + "/safe")
        try FileManager.default.createSymbolicLink(atPath: rule.outputFolder, withDestinationPath: d.path + "/safe")
        store.settings.watchFolders = [rule]
        let c = CoreFakeConverter(edges: [ConversionEdge("txt", "md")]) { step in
            if FilePath.fileName(step.inputPath) == "blocker.txt" { started.fulfill(); try await Task.sleep(nanoseconds: 20_000_000_000); return [] }
            XCTFail("Invalidated queued watch input must never reach the converter"); return []
        }
        let log = try d.file("wire.jsonl", ""), output = try FileHandle(forWritingTo: URL(fileURLWithPath: log))
        defer { try? output.close() }
        let wire = WireWriter(output.fileDescriptor)
        let host = Host(wire, store, [c], Localizer("en"), languageFixed: true, watcher: WatchFolderMonitor(), onStaging: { _ in })
        host.startWatching(); try await waitForWatch(host, state: "watching")
        _ = try host.handle("blocker", "job.start", ["paths": [try d.file("blocker.txt")], "targetFormat": "md"])
        await fulfillment(of: [started], timeout: 2)
        let source = try d.file("inbox/new.txt", "new input")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if hostObjects(hostObject(try host.handle("running", "watch.status", [:]))["rules"]).first?["state"] as? String == "running" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(hostObjects(hostObject(try host.handle("queued", "watch.status", [:]))["rules"]).first?["state"] as? String, "running")
        try FileManager.default.removeItem(atPath: rule.outputFolder)
        try FileManager.default.createSymbolicLink(atPath: rule.outputFolder, withDestinationPath: rule.originalsFolder)
        try await waitForWatch(host, state: "error")
        let id = try XCTUnwrap(hostObject(Self.messages(log).first { $0["id"] as? String == "blocker" }?["result"])["jobId"] as? String)
        _ = try host.handle("unblock", "job.cancel", ["jobId": id])
        var watchHistory: [String: Any]?
        let completed = Date().addingTimeInterval(3)
        while Date() < completed {
            let history = hostObjects(hostObject(try host.handle("history", "history.get", [:]))["entries"])
            watchHistory = history.first { $0["watchRuleId"] as? String == rule.id }
            if watchHistory != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(watchHistory?["state"] as? String, "cancelled")
        await host.cancelAll(3); wire.complete(1)
        XCTAssertEqual(store.history.first { $0.watchRuleId == rule.id }?.state, .cancelled)
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "saved original")
        XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "new input")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.path + "/safe/victim.md"))
        XCTAssertTrue(d.leftovers().isEmpty)
    }

    func testLoadedOriginalsAliasRuleIsBlockedAndSavingDirectOverlapIsRejected() throws {
        let d = CoreTempDir(), store = UserDataStore(d.path + "/core")
        try store.load()
        var preset = corePreset("md"); preset.id = "watch-preset"; preset.output.fileNamePattern = "victim"; preset.output.conflict = .overwrite
        store.presets.append(preset)
        var rule = WatchRule(); rule.folder = d.path + "/inbox"; rule.presetId = preset.id
        let saved = try d.file("inbox/originals/victim.md", "saved original")
        rule.outputFolder = d.path + "/originals-alias"
        try FileManager.default.createSymbolicLink(atPath: rule.outputFolder, withDestinationPath: rule.originalsFolder)
        store.settings.watchFolders = [rule]; try store.saveLibrary(); try store.saveSettings()
        let child = try HostChild(d.path); defer { child.close() }
        _ = try child.event("hello"); try waitForWatch(child, state: "error")
        let source = try d.file("inbox/new.txt", "new input")
        Thread.sleep(forTimeInterval: 4.1)
        XCTAssertTrue(hostObjects(try child.call("history.get")["entries"]).isEmpty)
        XCTAssertFalse(child.messages.contains { $0["event"] as? String == "job.finished" })
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "saved original")
        XCTAssertEqual(try String(contentsOfFile: source, encoding: .utf8), "new input")
        let library = try child.call("library.get")
        var settings = hostObject(library["settings"]); rule.outputFolder = rule.originalsFolder
        settings["watchFolders"] = [try WireJson.toNode(rule)]
        try child.request("reject-originals", "settings.save", ["baseRevision": library["revision"]!, "settings": settings])
        XCTAssertEqual(hostObject(try child.reply("reject-originals")["error"])["code"] as? String, "invalid_input")
        XCTAssertEqual(try child.call("library.get")["revision"] as? Int, library["revision"] as? Int)
    }

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
            _ = monitor.scan([rule], presets: store.presets, now: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - 10)
            let watched = try d.file("inbox/watched.txt")
            files[watched] = try XCTUnwrap(WatchFolderMonitor.Stamp.read(watched))
            _ = monitor.scan([rule], presets: store.presets, now: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - 10)
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
