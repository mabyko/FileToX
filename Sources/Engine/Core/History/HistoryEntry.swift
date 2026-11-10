import Foundation

/// Keeps the original fractional precision and offset; Foundation.Date alone loses .NET's 100 ns precision.
public struct EngineTimestamp: Codable, Equatable, Sendable {
    public var value: String
    public init(value: String) { self.value = value }
    public init(_ date: Date = Date()) {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let seconds = floor(date.timeIntervalSince1970)
        let fraction = Int(((date.timeIntervalSince1970 - seconds) * 10_000_000).rounded(.towardZero))
        var digits = String(format: "%07d", fraction); while digits.hasSuffix("0") { digits.removeLast() }
        let body = formatter.string(from: Date(timeIntervalSince1970: seconds)) + (digits.isEmpty ? "" : "." + digits)
        formatter.dateFormat = "xxx"; value = body + formatter.string(from: date)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer(); let s = try c.decode(String.self)
        guard let regex = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:\d{2})?$"#), regex.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid DateTime.") }
        let parts = s.prefix(19).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count == 6, (1...9999).contains(parts[0]), (1...12).contains(parts[1]), (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5]) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid DateTime.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let date = calendar.date(from: components), calendar.component(.month, from: date) == parts[1], calendar.component(.day, from: date) == parts[2] else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid DateTime.") }
        value = s
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(value) }
}
public struct HistoryFailure: Equatable, Sendable {
    public var source = ""
    public var errorKey: String?
    public var errorDetail: String?
    public init() {}
}
public struct HistoryEntry: Equatable, Sendable {
    public var jobId = ""
    public var finishedAt = EngineTimestamp(value: "0001-01-01T00:00:00")
    public var presetId = ""
    public var presetName = ""
    public var state = JobState.queued
    public var sources: [String] = []
    public var outputs: [String] = []
    public var watchRuleId: String?
    public var failures: [HistoryFailure] = []
    public var preset: Preset?
    public var errors: [String] = []
    public init() {}
    public static func from(_ job: ConversionJob) -> HistoryEntry {
        job.lock.withLock {
            var e = HistoryEntry(); e.finishedAt = EngineTimestamp(); e.jobId = job.id; e.presetId = job.preset.id; e.presetName = job.presetDisplayName
            e.state = job.state; e.sources = job.sources; e.outputs = job.outputs
            e.failures = job.files.filter { $0.state == .failed }.map { f in var failure = HistoryFailure(); failure.source = f.sourcePath; failure.errorKey = f.errorKey; failure.errorDetail = f.errorDetail; return failure }
            e.preset = e.failures.isEmpty ? nil : job.preset
            return e
        }
    }
}
public struct WatchFailure { public let failure: HistoryFailure; public let preset: Preset? }
public struct WatchResults {
    public let converted: Int; public let failures: [WatchFailure]
    public var isEmpty: Bool { converted == 0 && failures.isEmpty }
    public static func of(_ history: [HistoryEntry], _ ruleId: String) -> WatchResults {
        var seen = Set<String>(), converted = 0, failures: [WatchFailure] = []
        for e in history where e.watchRuleId == ruleId {
            for source in e.sources where seen.insert(FileSystemPaths.key(source)).inserted {
                if let f = e.failures.first(where: { FileSystemPaths.equal($0.source, source) }) { failures.append(WatchFailure(failure: f, preset: e.preset)) }
                else { converted += 1 }
            }
        }
        return WatchResults(converted: converted, failures: failures)
    }
}
