import Foundation

enum FileMenuAction: String, CaseIterable, Identifiable {
    case reveal, copyFiles, copyPaths
    var id: String { "action:" + rawValue }
    @MainActor var title: String { L("action.\(rawValue)") }
    var symbol: String {
        switch self { case .reveal: "folder"; case .copyFiles: "doc.on.clipboard"; case .copyPaths: "link" }
    }
}

enum RadialMenuEntry: Identifiable {
    case preset(HostSlice), action(FileMenuAction)
    var id: String {
        switch self { case .preset(let slice): "preset:" + slice.presetId; case .action(let action): action.id }
    }
    @MainActor var title: String {
        switch self { case .preset(let slice): slice.displayName; case .action(let action): action.title }
    }
    @MainActor var caption: String {
        switch self {
        case .preset(let slice): slice.targetFormat == "*" ? L("같은 형식") : slice.targetFormat.uppercased()
        case .action: L("menu.fileAction")
        }
    }
    var available: Bool {
        switch self { case .preset(let slice): slice.available; case .action: true }
    }
    var reason: String? {
        switch self { case .preset(let slice): slice.reasonText; case .action: nil }
    }
    var symbol: String? {
        switch self { case .preset: nil; case .action(let action): action.symbol }
    }
}
