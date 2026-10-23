import Foundation
import XCTest
@testable import FileToXEngineKit

final class HostChild {
    let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private let condition = NSCondition(), readers = DispatchGroup()
    private var lines: [[String: Any]] = []
    private var errorData = Data(), invalidCount = 0, nextId = 0
    var stderrText: String { condition.withLock { String(decoding:errorData,as:UTF8.self) } }
    var invalid: Int { condition.withLock { invalidCount } }
    var messages: [[String: Any]] { condition.withLock { lines } }
    init(_ root: String, data: String? = nil, language: String? = "en", fake: Bool = true) throws {
        let products = Bundle(for: HostProtocolTests.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("FileToXEngine")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else { throw ConversionError("Build FileToXEngine beside the test bundle: \(executable.path)") }
        process.executableURL = executable
        process.arguments = ["--data",data ?? root + "/core","--engines",root + "/engines","--tmp",root + "/tmp"] + (fake ? ["--fake-engines"] : []) + (language.map { ["--lang",$0] } ?? [])
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        readers.enter(); DispatchQueue.global().async { [self] in
            defer { readers.leave() }
            var pending = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let end = pending.firstIndex(of:10) {
                    let line = pending[..<end]; pending.removeSubrange(...end)
                    condition.withLock {
                        if let value = try? JSONSerialization.jsonObject(with:line) as? [String:Any] { lines.append(value) } else { invalidCount += 1 }
                        condition.broadcast()
                    }
                }
            }
        }
        readers.enter(); DispatchQueue.global().async { [self] in
            defer { readers.leave() }
            while true { let data = errors.fileHandleForReading.availableData; if data.isEmpty { break }; condition.withLock { errorData.append(data); condition.broadcast() } }
        }
    }
    func close() {
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit(); _ = readers.wait(timeout:.now()+3)
    }
    func send(_ line: String) throws { try input.fileHandleForWriting.write(contentsOf:Data((line + "\n").utf8)) }
    func request(_ id: String, _ method: String, _ params: [String:Any]) throws { try send(String(decoding:JSONSerialization.data(withJSONObject:["v":1,"id":id,"method":method,"params":params]),as:UTF8.self)) }
    func wait(_ timeout: TimeInterval = 30, _ predicate: ([[String:Any]]) -> Bool) throws {
        condition.lock(); defer { condition.unlock() }; let deadline = Date().addingTimeInterval(timeout)
        while !predicate(lines) { if !condition.wait(until:deadline) { throw ConversionError("Host timed out; stderr: \(String(decoding:errorData.suffix(2000),as:UTF8.self))") } }
    }
    func reply(_ id: String) throws -> [String:Any] { try wait { $0.contains { $0["id"] as? String == id } }; return messages.first { $0["id"] as? String == id }! }
    func call(_ method: String, _ params: [String:Any] = [:]) throws -> [String:Any] {
        nextId += 1; let id = "r\(nextId)"; try request(id,method,params)
        let response = try reply(id)
        guard let result = response["result"] as? [String:Any] else { throw ConversionError("\(method): \(response)") }; return result
    }
    func event(_ name: String, jobId: String? = nil) throws -> [String:Any] {
        func matches(_ m: [String:Any]) -> Bool { m["event"] as? String == name && (jobId == nil || (m["data"] as? [String:Any])?["jobId"] as? String == jobId) }
        try wait { $0.contains(where:matches) }; return messages.first(where:matches)!["data"] as! [String:Any]
    }
    func errorCode(_ id: String?, _ line: String) throws -> String? {
        let before = messages.count; try send(line)
        try wait { $0.dropFirst(before).contains { $0["error"] != nil && ($0["id"] as? String) == id } }
        return (messages.dropFirst(before).first { $0["error"] != nil && ($0["id"] as? String) == id }?["error"] as? [String:Any])?["code"] as? String
    }
}
func hostObjects(_ value: Any?) -> [[String:Any]] { value as? [[String:Any]] ?? [] }
func hostObject(_ value: Any?) -> [String:Any] { value as? [String:Any] ?? [:] }
func hostEqual(_ a: Any, _ b: Any) -> Bool { NSDictionary(dictionary:["value":a]).isEqual(to:["value":b]) }
