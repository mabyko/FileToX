import Foundation
import Darwin
import CoreFoundation

struct WireException: LocalizedError {
    let code: String, message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}
enum WireJson {
    static let maxLine = 4 * 1024 * 1024
    static func toNode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.userInfo[.engineWire] = true; encoder.outputFormatting = [.withoutEscapingSlashes]
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
    static func readStrict<T: Decodable>(_ type: T.Type, _ node: Any?, _ what: String) throws -> T {
        guard let node, !(node is NSNull) else { throw WireException("bad_request", "\(what) is missing.") }
        do {
            try validateIntegerFields(node)
            let data = try JSONSerialization.data(withJSONObject: node, options: [.fragmentsAllowed])
            let decoder = JSONDecoder(); decoder.userInfo[.engineStrict] = true
            return try decoder.decode(type, from: data)
        } catch { throw WireException("bad_request", "\(what): \(error)") }
    }
    static func parse(_ data: Data) throws -> Any {
        // Foundation accepts trailing commas; host-wire-v1 uses System.Text.Json's strict grammar.
        let bytes = Array(data)
        var quoted = false, escaped = false, depth = 0, last: UInt8?
        for byte in bytes {
            if quoted {
                if byte == 34 && !escaped { quoted = false }
                if byte == 92 { escaped.toggle() } else { escaped = false }
                continue
            }
            if byte == 34 { quoted = true; last = byte; continue }
            if [9, 10, 13, 32].contains(byte) { continue }
            if byte == 47 || ((byte == 93 || byte == 125) && last == 44) { throw WireException("bad_request", "Invalid JSON syntax.") }
            if byte == 91 || byte == 123 { depth += 1; if depth > 64 { throw WireException("bad_request", "JSON exceeds the maximum depth of 64.") } }
            if byte == 93 || byte == 125 { depth -= 1 }
            last = byte
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    private static func validateIntegerFields(_ value: Any) throws {
        let integerFields: Set<String> = ["schemaVersion", "quality", "resizePercent", "longEdge", "dpi", "renderDpi", "maxHeight", "audioBitrateKbps", "audioChannels", "audioSampleRate", "dragThreshold", "holdMilliseconds", "successfulConversions"]
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if integerFields.contains(key), child is NSNumber, integer(child) == nil { throw WireException("bad_request", "\(key) must be an integer.") }
                if key == "icoSizes", let values = child as? [Any], values.contains(where: { integer($0) == nil }) { throw WireException("bad_request", "icoSizes must contain integers.") }
                try validateIntegerFields(child)
            }
        } else if let list = value as? [Any] { for child in list { try validateIntegerFields(child) } }
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !String(cString: n.objCType).contains("d"), !String(cString: n.objCType).contains("f") else { return nil }
        guard n.int64Value >= Int32.min && n.int64Value <= Int32.max else { return nil }
        return Int(n.int64Value)
    }
}

/// A bounded queue and one writer preserve order while callers enqueue under the host gate.
final class WireWriter: @unchecked Sendable {
    private let output: Int32
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var closing = false, completed = false
    private let worker = DispatchQueue(label: "FileToXEngine.wire")
    var broken: (() -> Void)?
    init(_ output: Int32) { self.output = output; worker.async { self.pump() } }
    func response(_ id: String?, _ result: Any) { if !send(["v": 1, "id": id as Any? ?? NSNull(), "result": result]) { error(id, "internal", "The result is larger than \(WireJson.maxLine) bytes.") } }
    func error(_ id: String?, _ code: String, _ message: String) { _ = send(["v": 1, "id": id as Any? ?? NSNull(), "error": ["code": code, "message": message]]) }
    func event(_ name: String, _ data: Any) { _ = send(["v": 1, "event": name, "data": data]) }
    @discardableResult func send(_ message: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return false }
        data = EngineJsonEscaping.encode(data)
        data.append(10)
        if data.count > WireJson.maxLine { return false }
        condition.lock(); defer { condition.unlock() }
        while queue.count >= 4096 && !closing { condition.wait() }
        if closing { return false }
        queue.append(data); condition.broadcast(); return true
    }
    func fatal(_ code: String, _ message: String) {
        _ = send(["v": 1, "event": "fatal", "data": ["code": code, "message": message]])
        condition.lock(); closing = true; condition.broadcast(); condition.unlock()
        DispatchQueue.global().async { self.complete(2); self.broken?() }
    }
    func complete(_ timeout: TimeInterval) {
        condition.lock(); closing = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(timeout)
        while !completed { if !condition.wait(until: deadline) { break } }
        condition.unlock()
    }
    private func pump() {
        while true {
            condition.lock()
            while queue.isEmpty && !closing { condition.wait() }
            if queue.isEmpty { completed = true; condition.broadcast(); condition.unlock(); return }
            let data = queue.removeFirst(); condition.broadcast(); condition.unlock()
            let success = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }; offset += n
                }
                return true
            }
            if !success { condition.lock(); closing = true; queue.removeAll(); completed = true; condition.broadcast(); condition.unlock(); broken?(); return }
        }
    }
}

final class WireReader {
    private let input: Int32
    var shouldStop: () -> Bool = { false }
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var start = 0, end = 0
    init(_ input: Int32) { self.input = input }
    enum Line { case text(String), oversized, invalidUTF8 }
    func readLine() throws -> Line? {
        var line = Data(), oversized = false
        func decode() -> Line { if oversized { return .oversized }; if line.last == 13 { line.removeLast() }; return String(data: line, encoding: .utf8).map(Line.text) ?? .invalidUTF8 }
        while true {
            if start == end {
                if shouldStop() { return nil }
                var descriptor = pollfd(fd: input, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                if ready < 0 { throw ConversionError(String(cString: strerror(errno))) }
                start = 0; end = Darwin.read(input, &buffer, buffer.count)
                if end < 0 { if errno == EINTR { continue }; throw ConversionError(String(cString: strerror(errno))) }
                if end == 0 { return line.isEmpty && !oversized ? nil : decode() }
            }
            let newline = buffer[start..<end].firstIndex(of: 10), stop = newline ?? end
            if !oversized {
                if line.count + stop - start > WireJson.maxLine { oversized = true; line.removeAll() }
                else { line.append(contentsOf: buffer[start..<stop]) }
            }
            start = newline.map { $0 + 1 } ?? end
            if newline != nil { return decode() }
        }
    }
}
