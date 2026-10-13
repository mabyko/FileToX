import AppKit
import SwiftUI

enum ThemeAccent {
    static let defaultHex = "#3478F6"
    static func color(hex: String?) -> Color {
        let value = hex ?? defaultHex
        guard value.count == 7, value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) else { return color(hex: defaultHex) }
        return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    @MainActor static func hex(color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return defaultHex }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
    @MainActor static func foreground(on color: Color) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return .white }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722 > 0.179 ? .black : .white
    }
}

extension AppModel {
    var accentColor: Color {
        ThemeAccent.color(hex: library?.settings["theme"]?["accent"]?.string)
    }
    var themeColorScheme: ColorScheme? {
        switch library?.settings["theme"]?["mode"]?.string {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

/// Motion tokens adapted from transitions.dev (`--ease-smooth-out`, `--ease-bounce`, durations).
enum Motion {
    /// Opening dropdowns, panels, page swaps: 250ms smooth-out.
    static let open = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)
    /// Closing and text/icon swaps: 150ms, ~60% of open.
    static let quick = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.15)
    /// Small confirmations (selected wedge, check): 500ms with slight overshoot.
    static let pop = Animation.timingCurve(0.34, 1.36, 0.64, 1, duration: 0.5)
    static func when(_ enabled: Bool, _ animation: Animation) -> Animation? { enabled ? animation : nil }
}

extension AnyTransition {
    /// Text-swap / icon-swap: fade with 2px blur and a 4px lift (transitions.dev #04, #09).
    static var blurSwap: AnyTransition {
        .modifier(active: BlurSwap(progress: 0), identity: BlurSwap(progress: 1))
    }
}

private struct BlurSwap: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content.opacity(progress).blur(radius: (1 - progress) * 2).offset(y: (1 - progress) * 4)
    }
}
