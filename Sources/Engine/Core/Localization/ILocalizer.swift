import Foundation

public protocol ILocalizer: AnyObject {
    var language: String { get }
    subscript(key: String) -> String { get }
    func format(_ key: String, _ arguments: String...) -> String
}
public extension ILocalizer {
    func displayName(_ preset: Preset) -> String {
        !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? preset.name : preset.nameKey.map { self[$0] } ?? preset.targetFormat.uppercased()
    }
    func displayName(_ profile: ToolbarProfile) -> String {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? profile.name : profile.nameKey.map { self[$0] } ?? profile.id
    }
}
