import Foundation

// Filee FormatRegistry metadata (MIT); engine availability comes from the conversion host.
public struct FormatCatalog: Decodable, Sendable {
    public struct Upstream: Decodable, Sendable {
        public let repository: String
        public let commit: String
        public let source: String
        public let license: String
    }

    public let schemaVersion: Int
    public let upstream: Upstream
    public let formats: [FileFormatDefinition]

    public static func decode(_ data: Data) throws -> FormatCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        return catalog
    }

    public enum CatalogError: Error {
        case unsupportedSchema(Int)
    }
}

public struct FileFormatDefinition: Decodable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let category: String
    public let extensions: [String]
    public let writable: Bool
    public let isVirtual: Bool
}
