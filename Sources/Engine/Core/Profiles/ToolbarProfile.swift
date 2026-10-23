import Foundation

public struct ToolbarProfile: Equatable, Sendable {
    public static let maxSlices = 12
    public var id = Preset.newId()
    public var name = ""
    public var nameKey: String?
    public var extensions: [String] = []
    public var isFallback = false
    public var presetIds: [String] = []
    public init() {}
    public func matches(_ ext: String) -> Bool {
        extensions.contains { $0.caseInsensitiveCompare(String(ext.drop(while: { $0 == "." }))) == .orderedSame }
    }
}
public enum ProfileSelector {
    public static func select(_ profiles: [ToolbarProfile], _ filePaths: [String]) -> ToolbarProfile? {
        let extensions = filePaths.map(FormatRegistry.extensionOf)
        if !extensions.isEmpty, let match = profiles.first(where: { !$0.isFallback && extensions.allSatisfy($0.matches) })
            ?? profiles.first(where: { $0.isFallback && !$0.extensions.isEmpty && extensions.allSatisfy($0.matches) }) { return match }
        return catchAll(profiles)
    }
    public static func catchAll(_ profiles: [ToolbarProfile]) -> ToolbarProfile? {
        profiles.first { $0.isFallback && $0.extensions.isEmpty } ?? profiles.first { $0.isFallback } ?? profiles.first
    }
    public static func detectFormats(_ filePaths: [String]) -> [FileFormat] {
        var seen = Set<String>()
        return filePaths.compactMap(FormatRegistry.detect).filter { seen.insert($0.id).inserted }
    }
}
