import Foundation

// Preserve engine options, including fields the current editor does not expose.
indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var double: Double? { if case .number(let value) = self { value } else { nil } }
    var int: Int? {
        guard let value = double, value.isFinite, value.rounded() == value,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    subscript(key: String) -> JSONValue? {
        get { object?[key] }
        set { var value = object ?? [:]; value[key] = newValue; self = .object(value) }
    }
}

struct HostHello: Codable, Sendable {
    let `protocol`: Int
    let hostVersion: String
    let fileeCommit: String
    let rid: String
    let dataDir: String
}

struct HostCatalog: Decodable, Sendable {
    let formats: [FileFormatDefinition]
    let engines: [HostEngine]
}

struct HostEngine: Codable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let available: Bool
    let reasonKey: String?
    let detail: String?
    let version: String?
}

struct HostSelection: Codable, Sendable {
    let profileId: String?
    let formats: [String]
    let unknown: [String]
    let rejected: [HostRejectedInput]
    let slices: [HostSlice]
    let tools: [HostSlice]?
    let presetOptions: [HostSlice]?
    let targets: [HostTarget]
}

struct HostRejectedInput: Codable, Sendable {
    let path: String
    let reason: String
}

struct HostSlice: Codable, Sendable, Identifiable {
    let presetId: String
    let displayName: String
    let targetFormat: String
    let available: Bool
    let reasonKey: String?
    let reasonText: String?
    let runnableCount: Int
    let needsPackage: String?
    let canDownload: Bool
    let guidanceKey: String?
    var id: String { presetId }
}

struct HostTarget: Codable, Sendable, Identifiable {
    let formatId: String
    let available: Bool
    let reasonKey: String?
    let reasonText: String?
    let runnableCount: Int
    var id: String { formatId }
}

struct HostOutput: Codable, Sendable, Equatable, Identifiable {
    let path: String
    let isDirectory: Bool
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

struct HostFile: Decodable, Sendable, Identifiable {
    let source: String
    let state: String
    let progress: Double
    let outputs: [HostOutput]
    let errorKey: String?
    let errorDetail: String?
    var id: String { source }

    enum CodingKeys: CodingKey { case source, state, progress, outputs, errorKey, errorDetail }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        state = try c.decode(String.self, forKey: .state)
        progress = try c.decode(Double.self, forKey: .progress)
        outputs = try c.decodeIfPresent([HostOutput].self, forKey: .outputs) ?? []
        errorKey = try c.decodeIfPresent(String.self, forKey: .errorKey)
        errorDetail = try c.decodeIfPresent(String.self, forKey: .errorDetail)
    }
}

struct HostJob: Decodable, Sendable, Identifiable {
    let jobId: String
    let state: String
    let progress: Double
    let presetName: String
    let files: [HostFile]
    let historyEntry: HostHistory?
    let retrySources: [String]?
    let preset: JSONValue?
    var id: String { jobId }
    var outputs: [HostOutput] { files.flatMap(\.outputs) }
    var isFinished: Bool { ["completed", "completedWithErrors", "failed", "cancelled"].contains(state) }
}

struct HostHistory: Decodable, Sendable, Identifiable {
    let jobId: String
    let finishedAt: Date
    let presetId: String
    let presetName: String
    let state: String
    let sources: [String]
    let outputs: [String]
    let failures: [HostHistoryFailure]
    let preset: JSONValue?
    var id: String { jobId }
}

struct HostHistoryFailure: Codable, Sendable, Identifiable {
    let source: String
    let errorKey: String?
    let errorDetail: String?
    var id: String { source }
}

struct HostLibrary: Codable, Sendable {
    let revision: Int
    var settings: JSONValue
    var presets: [JSONValue]
    var profiles: [JSONValue]
}

enum HostEvent: Sendable {
    case hello(HostHello), updated(HostJob), finished(HostJob), fatal(String), interrupted(String)
}

struct HostError: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    static let interrupted = HostError(code: "host_crashed", message: "변환 엔진 연결이 끊겼습니다. 실행 중인 작업을 다시 확인하세요.")
}

extension JSONDecoder {
    static func hostDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: value) { return date }
            format.formatOptions = [.withInternetDateTime]
            if let date = format.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 timestamp"))
        }
        return decoder
    }
}
