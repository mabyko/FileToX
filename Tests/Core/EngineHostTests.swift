import Foundation
import Darwin
import XCTest
@testable import FileToXCore

final class EngineHostTests: XCTestCase {
    func testShutdownStopsWatchBeforeClosingHostInput() async throws {
        let fixture = try makeFixture(mode: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        _ = try await host.start()
        let rules = try await host.watchStatus()
        XCTAssertTrue(rules.isEmpty)
        await host.shutdown()
        let methods = try String(contentsOf: fixture.root.appendingPathComponent("methods.log"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(methods, ["watch.status", "watch.stop", "engine.install.stop", "engine.packages", "EOF"])
    }
    func testJSONDraftPreservesUnknownFieldsNullsAndArrayOrder() throws {
        let data = Data(#"{"dpi":null,"future":{"custom":true},"icoSizes":[256,32,16],"name":"Original"}"#.utf8)
        var draft = try JSONDecoder().decode(JSONValue.self, from: data)
        draft["name"] = .string("Edited")
        let result = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(result["dpi"], .null)
        XCTAssertEqual(result["future"]?["custom"]?.bool, true)
        XCTAssertEqual(result["icoSizes"]?.array?.compactMap(\.int), [256, 32, 16])
        XCTAssertEqual(result["name"]?.string, "Edited")
    }

    func testSelectionWithoutToolbarProfileStillProvidesTargets() throws {
        let data = Data(#"{"profileId":null,"formats":["png"],"unknown":[],"rejected":[],"slices":[],"targets":[{"formatId":"jpg","available":true,"runnableCount":1}]}"#.utf8)
        let selection = try JSONDecoder.hostDecoder().decode(HostSelection.self, from: data)
        XCTAssertNil(selection.profileId)
        XCTAssertTrue(selection.slices.isEmpty)
        XCTAssertTrue(selection.targets[0].available)
    }

    func testLineParserKeepsSplitUTF8AndRejectsOversizedUnterminatedLine() throws {
        var parser = HostLineBuffer()
        let bytes = Data("한글\r\nsecond\n".utf8)
        XCTAssertTrue(try parser.append(bytes.prefix(2)).isEmpty)
        let lines = try parser.append(bytes.dropFirst(2))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["한글", "second"])
        XCTAssertTrue(parser.remainder.isEmpty)
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: HostLineBuffer.maximumLength + 1)))
    }

    func testActualProcessCatalogAndInstantCompletionPreserveEventOrder() async throws {
        let fixture = try makeFixture(mode: "normal")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let events = await host.events()
        let finished = Task { () -> HostJob? in
            for await event in events {
                if case .finished(let job) = event { return job }
            }
            return nil
        }
        let hello = try await host.start()
        XCTAssertEqual(hello.protocol, 1)
        let catalog: HostCatalog
        do { catalog = try await host.catalog() }
        catch { let log = await host.diagnostics(); await host.shutdown(); XCTFail("Catalog: \(error), \(log)"); throw error }
        XCTAssertEqual(catalog.formats.count, 172)
        let selection = try await host.resolve(paths: ["/tmp/input.unknown"])
        XCTAssertEqual(selection.unknown, ["/tmp/input.unknown"])
        XCTAssertEqual(selection.slices.first?.presetId, "zip-all")
        let accepted = try await host.startJob(paths: ["/tmp/input.unknown"], presetId: "zip-all")
        let job = await finished.value
        XCTAssertEqual(job?.jobId, accepted)
        XCTAssertEqual(job?.outputs.map(\.path), ["/tmp/result.zip", "/tmp/sidecar"])
        XCTAssertEqual(job?.outputs.last?.isDirectory, true)
        XCTAssertEqual(job?.historyEntry?.preset?["dpi"], .null)
        await host.shutdown()
    }

    func testChunkAssemblerRejectsGapsChangedTransfersInvalidEncodingAndOversize() throws {
        let id = UUID().uuidString, total = HostLineBuffer.maximumLength + 20
        let first = HostMessageChunk(id: id, offset: 0, total: total, bytes: Data([65]).base64EncodedString())
        var initial = HostMessageAssembler()
        XCTAssertNil(try initial.append(first))
        XCTAssertTrue(initial.isReceiving)
        for invalid in [
            HostMessageChunk(id: id, offset: 0, total: total, bytes: "QQ=="),
            HostMessageChunk(id: id, offset: 2, total: total, bytes: "QQ=="),
            HostMessageChunk(id: UUID().uuidString, offset: 1, total: total, bytes: "QQ=="),
            HostMessageChunk(id: id, offset: 1, total: total + 1, bytes: "QQ=="),
            HostMessageChunk(id: id, offset: 1, total: total, bytes: "?"),
            HostMessageChunk(id: id, offset: 1, total: total, bytes: ""),
            HostMessageChunk(id: id, offset: 1, total: HostMessageAssembler.maximumLength + 1, bytes: "QQ=="),
            HostMessageChunk(id: "not-a-transfer-id", offset: 1, total: total, bytes: "QQ==")
        ] {
            var assembler = initial
            XCTAssertThrowsError(try assembler.append(invalid))
        }
        var assembler = HostMessageAssembler(), result: Data?
        let expected = Data(repeating: 65, count: total)
        for offset in stride(from: 0, to: total, by: 1024 * 1024) {
            let part = expected.subdata(in: offset..<min(total, offset + 1024 * 1024))
            result = try assembler.append(.init(id: id, offset: offset, total: total, bytes: part.base64EncodedString()))
        }
        XCTAssertEqual(result, expected)
        XCTAssertFalse(assembler.isReceiving)
        XCTAssertNil(try assembler.append(first))
    }

    func testChunkedCompletionAndHistoryRetainEveryOutputAndNextRequestWorks() async throws {
        let fixture = try makeFixture(mode: "chunked")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        let events = await host.events()
        let finished = Task { () -> HostJob? in
            for await event in events {
                if case .finished(let job) = event { return job }
                if case .interrupted = event { return nil }
            }
            return nil
        }
        _ = try await host.startJob(paths: ["/tmp/input.pdf"], targetFormat: "png")
        let job = await finished.value
        XCTAssertEqual(job?.outputs.count, 6_000)
        XCTAssertEqual(job?.outputs.last?.path, "/tmp/" + String(repeating: "페이지/", count: 40) + "5999.png")
        XCTAssertEqual(job?.historyEntry?.outputs, job?.outputs.map(\.path))
        let history = try await host.history()
        XCTAssertEqual(history.first?.outputs, job?.historyEntry?.outputs)
        let catalog = try await host.catalog()
        XCTAssertEqual(catalog.formats.count, 172)
        await host.shutdown()
    }

    func testMalformedResponseFailsEveryWaitingRequest() async throws {
        let fixture = try makeFixture(mode: "malformed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        _ = try await host.start()
        async let first: Bool = Self.fails { _ = try await host.catalog() }
        async let second: Bool = Self.fails { _ = try await host.library() }
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [true, true])
        await host.shutdown()
    }

    func testUnknownCommitFailsHandshakeWithoutSendingRequests() async throws {
        let fixture = try makeFixture(mode: "version")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        do { _ = try await host.start(); XCTFail("accepted wrong version") }
        catch { XCTAssertEqual((error as? HostError)?.code, "version_mismatch") }
        await host.shutdown()
    }

    @MainActor
    func testUnresponsiveCancellationKillsChildProcessAfterGracePeriod() async throws {
        let fixture = try makeFixture(mode: "stuck")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = EngineHost(executableURL: fixture.executable, dataDirectory: fixture.root.appendingPathComponent("data"))
        var interruption: String?
        let events = await host.events()
        let consumer = Task { @MainActor in
            for await event in events {
                if case .interrupted(let message) = event { interruption = message }
            }
        }
        do {
            let job = try await host.startJob(paths: ["/tmp/input.png"], targetFormat: "jpg")
            let pidText = try String(contentsOf: fixture.root.appendingPathComponent("child.pid"), encoding: .utf8)
            let childPID = try XCTUnwrap(Int32(pidText))
            XCTAssertEqual(kill(childPID, 0), 0)
            try await host.cancel(jobId: job)
            let deadline = ContinuousClock.now.advanced(by: .seconds(40))
            while interruption == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(interruption?.contains("취소에 응답하지 않는 엔진") == true)
            let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while kill(childPID, 0) == 0, ContinuousClock.now < cleanupDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(kill(childPID, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            await host.shutdown()
            consumer.cancel()
        } catch {
            await host.shutdown()
            consumer.cancel()
            throw error
        }
    }

    private static func fails(_ operation: @Sendable () async throws -> Void) async -> Bool {
        do { try await operation(); return false } catch { return true }
    }

    private func makeFixture(mode: String) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("filetox-host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture.py")
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/FileeFormats.json").path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let resourceLiteral = String(decoding: try encoder.encode(resource), as: UTF8.self)
        let script = """
        #!/usr/bin/env python3
        import json,sys,os,subprocess,base64,uuid
        os.setpgid(0,0)
        mode="\(mode)"
        def send(value):
            raw=json.dumps(value,ensure_ascii=True).encode()
            if mode=="chunked" and len(raw)>4*1024*1024:
                assert "--chunked-output" in sys.argv
                transfer=str(uuid.uuid4())
                for offset in range(0,len(raw),2*1024*1024):
                    print(json.dumps({"v":1,"chunk":{"id":transfer,"offset":offset,"total":len(raw),"bytes":base64.b64encode(raw[offset:offset+2*1024*1024]).decode()}}),flush=True)
            else:print(raw.decode(),flush=True)
        many=["/tmp/"+"페이지/"*40+str(i)+".png" for i in range(6000)] if mode=="chunked" else []
        last_history=None
        send({"v":1,"event":"hello","data":{"protocol":1,"hostVersion":"test","fileeCommit":"wrong" if mode=="version" else "21fdd05ef7181b032ed83ec895cc9bbc4b198985","rid":"osx-arm64","dataDir":"/tmp/data"}})
        for line in sys.stdin:
            request=json.loads(line)
            with open(os.path.join(os.path.dirname(__file__),"methods.log"),"a") as f:f.write(request["method"]+"\\n")
            if mode=="malformed":
                send({"v":1,"id":request["id"]})
                continue
            method=request["method"]
            result={}
            if method=="catalog.get":
                with open(\(resourceLiteral)) as f:formats=json.load(f)["formats"]
                result={"formats":formats,"engines":[]}
            if method=="library.get":result={"revision":1,"settings":{},"presets":[],"profiles":[]}
            if method=="watch.status":result={"rules":[]}
            if method=="history.get":result={"entries":[last_history] if last_history else []}
            if method=="engine.packages":result={"packages":[]}
            if method=="selection.resolve":
                result={"profileId":"mixed","formats":[],"unknown":request["params"]["paths"],"rejected":[],"targets":[],"slices":[{"presetId":"zip-all","displayName":"ZIP","targetFormat":"zip","available":True,"runnableCount":1,"canDownload":False}]}
            if method=="job.start":
                result={"jobId":"instant"}
                if mode=="stuck":
                    child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(90)"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                    with open(os.path.join(os.path.dirname(__file__),"child.pid"),"w") as f:f.write(str(child.pid))
            send({"v":1,"id":request["id"],"result":result})
            if method=="job.start" and mode!="stuck":
                sys.stderr.write("native log "*10000)
                sys.stderr.flush()
                history={"jobId":"instant","finishedAt":"2026-10-11T16:05:10.1234567+09:00","presetId":"zip-all","presetName":"ZIP","state":"completed","sources":["/tmp/input.unknown"],"outputs":["/tmp/result.zip","/tmp/sidecar"],"failures":[],"preset":{"dpi":None}}
                outputs=[{"path":p,"isDirectory":False} for p in many] if many else [{"path":"/tmp/result.zip","isDirectory":False},{"path":"/tmp/sidecar","isDirectory":True}]
                if many:history["outputs"]=many
                last_history=history
                send({"v":1,"event":"job.finished","data":{"jobId":"instant","state":"completed","progress":1,"presetName":"ZIP","files":[{"source":"/tmp/input.unknown","state":"done","progress":1,"outputs":outputs}],"historyEntry":history}})
        with open(os.path.join(os.path.dirname(__file__),"methods.log"),"a") as f:f.write("EOF\\n")
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }
}
