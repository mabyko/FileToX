import Foundation

/// The command-line smoke entry remains available without XCTest or any real conversion engines.
enum EngineHostSelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print(condition ? "  ok   \(name)" : "  FAIL \(name)")
            if !condition { failures += 1 }
        }
        do {
            let root = FilePath.combine(NSTemporaryDirectory(), "ftx-selftest-" + Preset.newId())
            try FileManager.default.createDirectoryIfNeeded(root)
            defer { FileManager.default.removeIfPresent(root) }
            check(Localizer("ja-JP")["preset.half_size"] == "サイズを半分に", "Japanese localization")
            check(Localizer.resolve("auto") == "en", "automatic language")
            let store = UserDataStore(root + "/defaults"); try store.load(); try EngineHostMain.applyDefaults(store)
            check(store.settings.language == "en" && store.settings.theme.accent == "#3478F6", "FileToX defaults")
            let presets = BuiltInData.createPresets(), node = try WireJson.toNode(presets)
            check(try WireJson.readStrict([Preset].self, node, "presets") == presets, "strict preset round-trip")
            try Validation.library(presets, BuiltInData.createProfiles()); check(true, "built-in validation")
            let child = try Child(root)
            defer { child.close() }
            let hello = try child.wait { $0["event"] as? String == "hello" }
            check((hello["data"] as? [String: Any])?["protocol"] as? Int == 1, "hello")
            let source = root + "/a.txt"; try Data("original".utf8).write(to: URL(fileURLWithPath: source))
            for i in 0..<1000 { try child.send(["v":1,"id":"j\(i)","method":"job.start","params":["paths":[source],"targetFormat":"md"]]) }
            try child.waitForFinished(1000)
            let lines = child.snapshot
            var responded = Set<String>(), finished = Set<String>(), ordered = true
            for line in lines {
                if let id = (line["result"] as? [String: Any])?["jobId"] as? String { ordered = responded.insert(id).inserted && ordered }
                else if ["job.updated", "job.finished"].contains(line["event"] as? String ?? ""), let id = (line["data"] as? [String: Any])?["jobId"] as? String {
                    ordered = responded.contains(id) && !finished.contains(id) && ordered
                    if line["event"] as? String == "job.finished" { finished.insert(id) }
                }
            }
            check(ordered && responded.count == 1000 && finished.count == 1000, "1,000 jobs: response → updates → one finished")
            check(try String(contentsOfFile: source, encoding: .utf8) == "original", "source untouched")
            child.close(); check(child.noise.contains("native-noise-without-newline") && child.invalid == 0, "native stdout noise isolated")
        } catch { print("  FAIL \(error)"); failures += 1 }
        print(failures == 0 ? "SELFTEST PASSED" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
    private final class Child {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let condition = NSRecursiveLock(), ready = DispatchSemaphore(value: 0), readers = DispatchGroup()
        var lines: [[String: Any]] = [], noise = "", invalid = 0
        var snapshot: [[String: Any]] { condition.withLock { lines } }
        var finishedCount: Int { condition.withLock { lines.filter { $0["event"] as? String == "job.finished" }.count } }
        init(_ root: String) throws {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--fake-engines", "--data", root + "/core", "--engines", root + "/engines", "--tmp", root + "/tmp"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            readers.enter(); DispatchQueue.global().async { [self] in
                defer { readers.leave() }; var pending = Data()
                while true {
                    let data = output.fileHandleForReading.availableData; if data.isEmpty { break }; pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        let data = pending[..<end]; pending.removeSubrange(...end)
                        condition.withLock { if let line = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { lines.append(line) } else { invalid += 1 } }; ready.signal()
                    }
                }
            }
            readers.enter(); DispatchQueue.global().async { [self] in
                defer { readers.leave() }
                while true { let data = errors.fileHandleForReading.availableData; if data.isEmpty { break }; condition.withLock { noise += String(decoding: data, as: UTF8.self) } }
            }
        }
        func send(_ message: [String: Any]) throws { var data = try JSONSerialization.data(withJSONObject: message); data.append(10); try input.fileHandleForWriting.write(contentsOf: data) }
        func wait(_ predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
            let deadline = DispatchTime.now() + 120
            while true {
                if let line = condition.withLock({ lines.first(where: predicate) }) { return line }
                if ready.wait(timeout: deadline) == .timedOut { throw ConversionError("Self-test host timed out.") }
            }
        }
        func waitForFinished(_ count: Int) throws {
            let deadline = DispatchTime.now() + 120
            while finishedCount < count { if ready.wait(timeout: deadline) == .timedOut { throw ConversionError("Self-test jobs timed out.") } }
        }
        func close() { try? input.fileHandleForWriting.close(); process.waitUntilExit(); _ = readers.wait(timeout: .now() + 2) }
    }
}
