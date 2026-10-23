import Foundation

public struct ModifierKeys: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let ctrl = Self(rawValue: 1), alt = Self(rawValue: 2), shift = Self(rawValue: 4), meta = Self(rawValue: 8)
}
public enum TriggerMouseButton: String, CaseIterable, Sendable { case none = "None", left = "Left", right = "Right", middle = "Middle", x1 = "X1", x2 = "X2" }
public enum TriggerKind: String, CaseIterable, Sendable { case drag = "Drag", hold = "Hold", keyChord = "KeyChord" }
public enum TriggerScope: String, CaseIterable, Sendable { case fileManager = "FileManager", anywhere = "Anywhere" }
public struct TriggerGesture: Equatable, Sendable {
    public var id = String(Preset.newId().prefix(8))
    public var enabled = true
    public var kind = TriggerKind.drag
    public var modifiers = ModifierKeys.ctrl
    public var button = TriggerMouseButton.left
    public var key: String?
    public var dragThreshold = 0
    public var holdMilliseconds = 450
    public var scope = TriggerScope.fileManager
    public init() {}
    public static func defaults() -> [Self] {
        var drag = Self(); drag.modifiers = .alt
        var chord = Self(); chord.kind = .keyChord; chord.modifiers = [.ctrl, .alt]; chord.button = .none; chord.key = "Space"
        return [drag, chord]
    }
}
