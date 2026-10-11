import Foundation

// Filee FormatRegistry metadata (MIT); engine availability comes from the conversion host.
struct FormatCatalog: Decodable, Sendable {
    struct Upstream: Decodable, Sendable {
        let repository: String
        let commit: String
        let source: String
        let license: String
    }

    let schemaVersion: Int
    let upstream: Upstream
    let formats: [FileFormatDefinition]

    static func decode(_ data: Data) throws -> FormatCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1 else {
            throw CatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        return catalog
    }

    enum CatalogError: Error {
        case unsupportedSchema(Int)
    }
}

struct FileFormatDefinition: Decodable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let category: String
    let extensions: [String]
    let writable: Bool
    let isVirtual: Bool
}
