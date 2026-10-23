import Foundation

// Preserve engine options, including fields the current editor does not expose.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
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

    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var double: Double? { if case .number(let value) = self { value } else { nil } }
    public var int: Int? {
        guard let value = double, value.isFinite, value.rounded() == value,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public subscript(key: String) -> JSONValue? {
        get { object?[key] }
        set { var value = object ?? [:]; value[key] = newValue; self = .object(value) }
    }
}

public struct HostHello: Codable, Sendable {
    public let `protocol`: Int
    public let hostVersion: String
    public let fileeCommit: String
    public let rid: String
    public let dataDir: String
}

public struct HostCatalog: Decodable, Sendable {
    public let formats: [FileFormatDefinition]
    public let engines: [HostEngine]
}

public struct HostEngine: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let available: Bool
    public let reasonKey: String?
    public let detail: String?
    public let version: String?
}

public struct HostSelection: Codable, Sendable {
    public let profileId: String?
    public let formats: [String]
    public let unknown: [String]
    public let rejected: [HostRejectedInput]
    public let slices: [HostSlice]
    public let tools: [HostSlice]?
    public let presetOptions: [HostSlice]?
    public let targets: [HostTarget]
}

public struct HostRejectedInput: Codable, Sendable {
    public let path: String
    public let reason: String
}

public struct HostSlice: Codable, Sendable, Identifiable {
    public let presetId: String
    public let displayName: String
    public let targetFormat: String
    public let available: Bool
    public let reasonKey: String?
    public let reasonText: String?
    public let runnableCount: Int
    public let needsPackage: String?
    public let canDownload: Bool
    public let guidanceKey: String?
    public var id: String { presetId }
}

public struct HostTarget: Codable, Sendable, Identifiable {
    public let formatId: String
    public let available: Bool
    public let reasonKey: String?
    public let reasonText: String?
    public let runnableCount: Int
    public var id: String { formatId }
}

public struct HostOutput: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let isDirectory: Bool
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

public struct HostFile: Decodable, Sendable, Identifiable {
    public let source: String
    public let state: String
    public let progress: Double
    public let outputs: [HostOutput]
    public let errorKey: String?
    public let errorDetail: String?
    public var id: String { source }

    public enum CodingKeys: CodingKey { case source, state, progress, outputs, errorKey, errorDetail }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        state = try c.decode(String.self, forKey: .state)
        progress = try c.decode(Double.self, forKey: .progress)
        outputs = try c.decodeIfPresent([HostOutput].self, forKey: .outputs) ?? []
        errorKey = try c.decodeIfPresent(String.self, forKey: .errorKey)
        errorDetail = try c.decodeIfPresent(String.self, forKey: .errorDetail)
    }
}

public struct HostJob: Decodable, Sendable, Identifiable {
    public let jobId: String
    public let state: String
    public let progress: Double
    public let presetName: String
    public let files: [HostFile]
    public let historyEntry: HostHistory?
    public let retrySources: [String]?
    public let preset: JSONValue?
    public var id: String { jobId }
    public var outputs: [HostOutput] { files.flatMap(\.outputs) }
    public var isFinished: Bool { ["completed", "completedWithErrors", "failed", "cancelled"].contains(state) }
}

public struct HostHistory: Decodable, Sendable, Identifiable {
    public let jobId: String
    public let finishedAt: Date
    public let presetId: String
    public let presetName: String
    public let state: String
    public let sources: [String]
    public let outputs: [String]
    public let failures: [HostHistoryFailure]
    public let preset: JSONValue?
    public var id: String { jobId }
}

public struct HostHistoryFailure: Codable, Sendable, Identifiable {
    public let source: String
    public let errorKey: String?
    public let errorDetail: String?
    public var id: String { source }
}

public struct HostLibrary: Codable, Sendable {
    public let revision: Int
    public var settings: JSONValue
    public var presets: [JSONValue]
    public var profiles: [JSONValue]
}

public enum HostEvent: Sendable {
    case hello(HostHello), updated(HostJob), finished(HostJob), fatal(String), interrupted(String)
}

public struct HostError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public static let interrupted = HostError(code: "host_crashed", message: "변환 엔진 연결이 끊겼습니다. 실행 중인 작업을 다시 확인하세요.")
}

extension JSONDecoder {
    public static func hostDecoder() -> JSONDecoder {
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
