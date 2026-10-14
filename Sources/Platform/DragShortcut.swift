import AppKit
import Carbon

struct DragShortcut: Codable, Equatable {
    static let defaultsKey = "dragShortcut"
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    static let standard = DragShortcut(modifiers: .control)

    var modifierBits: UInt
    var keyCode: UInt16?
    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: modifierBits) }
        set { modifierBits = newValue.intersection(Self.modifierMask).rawValue }
    }

    init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16? = nil) {
        modifierBits = modifiers.intersection(Self.modifierMask).rawValue
        self.keyCode = keyCode
    }

    var isValid: Bool {
        !modifiers.isEmpty && modifiers.intersection(Self.modifierMask) == modifiers &&
            (keyCode == nil || Self.keys.contains { $0.code == keyCode })
    }

    var displayName: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() +
            (Self.keys.first { $0.code == keyCode }?.name ?? "")
    }

    func matches(modifiers pressed: NSEvent.ModifierFlags, keyPressed: Bool = false) -> Bool {
        isValid && pressed.intersection(Self.modifierMask) == modifiers && (keyCode == nil || keyPressed)
    }

    static func load(from defaults: UserDefaults) -> DragShortcut {
        guard let data = defaults.data(forKey: defaultsKey),
              let shortcut = try? JSONDecoder().decode(Self.self, from: data), shortcut.isValid else { return .standard }
        return shortcut
    }

    func save(to defaults: UserDefaults) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    struct Key: Identifiable {
        let code: UInt16
        let name: String
        var id: UInt16 { code }
    }

    // Virtual key codes refer to physical positions in the US keyboard layout.
    static let keys: [Key] = [
        (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"),
        (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"),
        (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"),
        (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
        (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
        (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        (105, "F13"), (107, "F14"), (113, "F15"), (106, "F16"), (64, "F17"), (79, "F18"), (80, "F19"), (90, "F20"),
        (49, "Space"), (123, "←"), (124, "→"), (126, "↑"), (125, "↓")
    ].map { Key(code: UInt16($0.0), name: $0.1) }

    struct SystemHotKey {
        let keyCode: UInt16
        let carbonModifiers: UInt32
        let enabled: Bool
    }

    func conflicts(with hotKeys: [SystemHotKey]) -> Bool {
        guard isValid else { return false }
        let code = keyCode ?? UInt16.max
        var carbonModifiers: UInt32 = 0
        for (flag, bit) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if modifiers.contains(flag) { carbonModifiers |= UInt32(bit) }
        }
        let mask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        // Match the same four modifiers as activation; Fn/Caps Lock do not change the configured combination.
        return hotKeys.contains { $0.enabled && $0.keyCode == code && $0.carbonModifiers & mask == carbonModifiers }
    }

    @MainActor
    static func systemHotKeys() -> [SystemHotKey]? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            guard let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                  let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool else { return nil }
            return SystemHotKey(keyCode: code.uint16Value, carbonModifiers: modifiers.uint32Value, enabled: enabled)
        }
    }
}
