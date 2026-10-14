import Foundation
import XCTest
@testable import FileToX

final class AppModelTests: XCTestCase {
    @MainActor
    func testShortcutSavesWithSettingsAndFailedSavePreservesPreviousShortcut() async throws {
        let fixture = try makeFixture()
        let suite = "filetox-shortcut-model-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host, defaults: defaults)
        let shortcut = DragShortcut(modifiers: [.control, .shift], keyCode: 40)
        XCTAssertEqual(model.dragShortcut, .standard)
        await model.connect()
        let settings = try XCTUnwrap(model.library?.settings)
        let saved = await model.saveSettings(settings, dragShortcut: shortcut)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.dragShortcut, shortcut)
        XCTAssertEqual(AppModel(defaults: defaults).dragShortcut, shortcut)
        XCTAssertNil(model.library?.settings["dragShortcut"], "Platform settings must not enter the strict engine schema")
        let failed = await model.saveSettings(settings, baseRevision: -1, dragShortcut: .standard)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.dragShortcut, shortcut)
        XCTAssertEqual(DragShortcut.load(from: defaults), shortcut)
        let invalid = await model.saveSettings(settings, dragShortcut: DragShortcut(modifiers: []))
        XCTAssertFalse(invalid)
        XCTAssertEqual(model.dragShortcut, shortcut)
        let generalSave = await model.saveSettings(settings)
        XCTAssertTrue(generalSave)
        XCTAssertEqual(model.dragShortcut, shortcut)
        await host.shutdown()
    }

    @MainActor
    func testSelectionRejectsRemoteURLsAndPreservesOrderWithoutDuplicates() {
        let model = AppModel()
        let first = URL(fileURLWithPath: "/tmp/첫 사진.png")
        let second = URL(fileURLWithPath: "/tmp/second.png")
        model.selectFiles([first, second, first, URL(string: "https://example.com/image.png")!, URL(string: "file://remote/shared.png")!])
        XCTAssertEqual(model.selectedFiles, [first, second])
    }

    @MainActor
    func testOnlyLatestResolveResponseCanChooseFilesAndTargets() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        XCTAssertTrue(model.isConnected)
        let slow = Task { await model.resolve([URL(fileURLWithPath: "/tmp/slow.png")], showRadial: false) }
        try await Task.sleep(for: .milliseconds(30))
        await model.resolve([URL(fileURLWithPath: "/tmp/latest.unknown")], showRadial: false)
        await slow.value
        XCTAssertEqual(model.selectedFiles.map(\.path), ["/tmp/latest.unknown"])
        XCTAssertEqual(model.selection?.unknown, ["/tmp/latest.unknown"])
        XCTAssertFalse(model.isResolving)
        await host.shutdown()
    }

    @MainActor
    func testCancellationWaitsForTerminalEventAndKeepsAllOutputs() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        await model.resolve([URL(fileURLWithPath: "/tmp/archive.unknown")], showRadial: false)
        await model.start(presetID: "zip-all")
        try await wait { model.activeJobs.count == 1 }
        await model.cancel(jobID: "one")
        XCTAssertTrue(model.cancellingJobIDs.contains("one"))
        try await wait { model.historyEntries.count == 1 }
        XCTAssertFalse(model.isConverting)
        XCTAssertTrue(model.cancellingJobIDs.isEmpty)
        XCTAssertEqual(model.historyEntries.first?.outputs, ["/tmp/first.zip", "/tmp/sidecar"])
        XCTAssertEqual(model.jobs.first?.files.first?.outputs.count, 2)
        await host.shutdown()
    }

    @MainActor
    func testInstantFinishedEventBeforeStartResponseStillClosesRadial() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        await model.resolve([URL(fileURLWithPath: "/tmp/instant.unknown")], showRadial: false)
        await model.start(presetID: "zip-all")
        try await wait { model.historyEntries.count == 1 }
        XCTAssertEqual(model.radialJobID, "instant")
        try await wait { !model.radialVisible }
        XCTAssertFalse(model.isConverting)
        await host.shutdown()
    }

    @MainActor
    func testRadialGeometryIsFrozenUntilNextInvocation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        model.prepareForDrag()
        var settings = try XCTUnwrap(model.library?.settings)
        settings.set(.number(240), at: ["donut", "outerRadius"])
        await model.saveSettings(settings)
        XCTAssertEqual(model.outerRadius, 240)
        XCTAssertEqual(model.radialOuterRadius, 150)
        model.prepareForDrag()
        XCTAssertEqual(model.radialOuterRadius, 240)
        await host.shutdown()
    }

    @MainActor
    func testLanguageAndAccentSaveRefreshSelectionAndSurviveSettingsReload() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        await model.resolve([URL(fileURLWithPath: "/tmp/photo.png")], showRadial: false)
        model.prepareForDrag()
        await model.resolve([URL(fileURLWithPath: "/tmp/photo.png")], clickMode: false, showRadial: false)
        XCTAssertEqual(model.selection?.slices.first?.displayName, "Combine ZIP")
        var settings = try XCTUnwrap(model.library?.settings)
        settings["language"] = .string("ja")
        settings.set(.string("#12AB34"), at: ["theme", "accent"])
        settings.set(.number(240), at: ["donut", "outerRadius"])
        let saved = await model.saveSettings(settings)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.language, .japanese)
        XCTAssertEqual(model.selection?.slices.first?.displayName, "ZIPにまとめる")
        XCTAssertEqual(model.radialOuterRadius, 150, "An open drag must keep its captured geometry")
        await model.refreshLibrary()
        XCTAssertEqual(model.language, .japanese)
        XCTAssertEqual(model.library?.settings["theme"]?["accent"]?.string, "#12AB34")
        await host.shutdown()
    }

    @MainActor
    func testSettingsSaveRefreshesEngineAvailability() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        XCTAssertEqual(model.catalog?.engines.first?.available, false)
        var settings = try XCTUnwrap(model.library?.settings)
        settings.set(.string("/tmp/ffmpeg"), at: ["engineOwnCopies", "ffmpeg"])
        let saved = await model.saveSettings(settings)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.catalog?.engines.first?.available, true)
        await host.shutdown()
    }

    @MainActor
    func testOpeningSameResolvedFilesReopensClosedClickDonut() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        await model.connect()
        var shownCount = 0
        model.onShowRadial = { _, _ in shownCount += 1 }
        let files = [URL(fileURLWithPath: "/tmp/reopen.png")]
        await model.resolve(files)
        model.closeRadial()
        await model.resolve(files)
        XCTAssertTrue(model.radialVisible)
        XCTAssertTrue(model.radialClickMode)
        XCTAssertEqual(shownCount, 2)
        XCTAssertEqual(model.selection?.unknown, files.map(\.path))
        await host.shutdown()
    }

    @MainActor
    func testConcurrentConnectWaitsForMetadataBeforeResolvingInitialOpen() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let model = AppModel(host: host)
        let firstConnection = Task { await model.connect() }
        try await wait { model.isConnecting }
        await model.connect()
        XCTAssertTrue(model.isConnected)
        await model.resolve([URL(fileURLWithPath: "/tmp/cold-open.png")], showRadial: false)
        XCTAssertEqual(model.selection?.unknown, ["/tmp/cold-open.png"])
        await firstConnection.value
        await host.shutdown()
    }

    @MainActor
    func testCompletedHistoryAndJobsAreCappedWithoutDroppingActiveJobs() throws {
        let model = AppModel()
        func job(_ id: String, state: String) throws -> HostJob {
            let history: [String: Any] = ["jobId": id, "finishedAt": "2026-10-11T10:00:00Z", "presetId": "zip-all", "presetName": "ZIP", "state": state, "sources": [], "outputs": [], "failures": []]
            var value: [String: Any] = ["jobId": id, "state": state, "progress": state == "running" ? 0.2 : 1, "presetName": "ZIP", "files": []]
            if state != "running" { value["historyEntry"] = history }
            return try JSONDecoder.hostDecoder().decode(HostJob.self, from: JSONSerialization.data(withJSONObject: value))
        }
        model.consume(.updated(try job("active-oldest", state: "running")))
        for index in 0..<225 { model.consume(.finished(try job("finished-\(index)", state: "completed"))) }
        XCTAssertEqual(model.historyEntries.count, 200)
        XCTAssertEqual(model.historyEntries.first?.jobId, "finished-224")
        XCTAssertEqual(model.historyEntries.last?.jobId, "finished-25")
        XCTAssertEqual(model.jobs.count, 201)
        XCTAssertEqual(model.activeJobs.map(\.jobId), ["active-oldest"])
        model.consume(.interrupted("fixture disconnected"))
        XCTAssertTrue(model.activeJobs.isEmpty)
        XCTAssertEqual(model.jobs.count, 200)
    }

    @MainActor
    func testNestedEditorChangePreservesUnknownFieldsNullsAndOrder() throws {
        var draft = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"image":{"quality":90,"dpi":null,"future":[256,16]},"other":{"x":true}}"#.utf8))
        draft.set(.number(70), at: ["image", "quality"])
        XCTAssertEqual(draft.field("image").field("quality").int, 70)
        XCTAssertEqual(draft.field("image").field("dpi"), .null)
        XCTAssertEqual(draft.field("image").field("future").array?.compactMap(\.int), [256, 16])
        XCTAssertEqual(draft.field("other").field("x").bool, true)
    }

    @MainActor
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    private func makeFixture() throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filetox-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("host.py")
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,os,threading
        os.setpgid(0,0)
        lock=threading.Lock()
        configured=False
        settings={}
        revision=1
        def send(value):
            with lock:print(json.dumps(value),flush=True)
        def response(request,result):send({"v":1,"id":request["id"],"result":result})
        send({"v":1,"event":"hello","data":{"protocol":1,"hostVersion":"test","fileeCommit":"21fdd05ef7181b032ed83ec895cc9bbc4b198985","rid":"osx-arm64","dataDir":"/tmp/data"}})
        for line in sys.stdin:
            r=json.loads(line);m=r["method"]
            if m=="catalog.get":response(r,{"formats":[],"engines":[{"id":"ffmpeg","displayName":"FFmpeg","available":configured}]})
            elif m=="library.get":threading.Timer(.1,response,args=(r,{"revision":revision,"settings":settings,"presets":[],"profiles":[]})).start()
            elif m=="history.get":response(r,{"entries":[]})
            elif m=="settings.save":
                if r["params"]["baseRevision"]!=revision:
                    send({"v":1,"id":r["id"],"error":{"code":"revision_conflict","message":"Settings changed"}})
                    continue
                configured=True
                settings=r["params"]["settings"]
                revision+=1
                response(r,{"revision":revision,"settings":settings,"presets":[],"profiles":[]})
            elif m=="selection.resolve":
                p=r["params"]["paths"]
                displayName={"en":"Combine ZIP","ko":"ZIP 압축","ja":"ZIPにまとめる"}.get(settings.get("language","en"),"Combine ZIP")
                result={"profileId":"mixed","formats":[],"unknown":p,"rejected":[],"slices":[{"presetId":"zip-all","displayName":displayName,"targetFormat":"zip","available":True,"runnableCount":1,"canDownload":False}],"targets":[]}
                if "slow" in p[0]:threading.Timer(.2,response,args=(r,result)).start()
                else:response(r,result)
            elif m=="job.start":
                if "instant" in r["params"]["paths"][0]:
                    history={"jobId":"instant","finishedAt":"2026-10-11T10:00:00Z","presetId":"zip-all","presetName":"ZIP","state":"completed","sources":["/tmp/instant.unknown"],"outputs":["/tmp/first.zip"],"failures":[],"preset":None}
                    send({"v":1,"event":"job.finished","data":{"jobId":"instant","state":"completed","progress":1,"presetName":"ZIP","files":[],"historyEntry":history}})
                    response(r,{"jobId":"instant"})
                    continue
                response(r,{"jobId":"one"})
                send({"v":1,"event":"job.updated","data":{"jobId":"one","state":"running","progress":0.2,"presetName":"ZIP","files":[{"source":"/tmp/archive.unknown","state":"running","progress":0.2}]}})
            elif m=="job.cancel":
                response(r,{})
                history={"jobId":"one","finishedAt":"2026-10-11T10:00:00Z","presetId":"zip-all","presetName":"ZIP","state":"cancelled","sources":["/tmp/archive.unknown"],"outputs":["/tmp/first.zip","/tmp/sidecar"],"failures":[],"preset":{"name":"ZIP"}}
                job={"jobId":"one","state":"cancelled","progress":0.4,"presetName":"ZIP","files":[{"source":"/tmp/archive.unknown","state":"completed","progress":1,"outputs":[{"path":"/tmp/first.zip","isDirectory":False},{"path":"/tmp/sidecar","isDirectory":True}]}],"historyEntry":history}
                threading.Timer(.1,send,args=({"v":1,"event":"job.finished","data":job},)).start()
            else:response(r,{})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }
}
