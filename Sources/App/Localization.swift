import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en", korean = "ko", japanese = "ja"
    var id: String { rawValue }
    var nativeName: String {
        switch self { case .english: "English"; case .korean: "한국어"; case .japanese: "日本語" }
    }
    static func supported(_ identifier: String?) -> AppLanguage {
        let code = identifier?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        return code.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

@MainActor @Observable
final class Localization {
    static let shared = Localization()
    var language: AppLanguage = .english

    nonisolated static func text(_ key: String, language: AppLanguage, bundle: Bundle = .main) -> String {
        func lookup(_ code: String) -> String? {
            guard let path = bundle.path(forResource: code, ofType: "lproj"), let localized = Bundle(path: path) else { return nil }
            let missing = "\u{1}missing:\(key)"
            let result = localized.localizedString(forKey: key, value: missing, table: "Localizable")
            return result == missing ? nil : result
        }
        return lookup(language.rawValue) ?? lookup("en") ?? key
    }

    nonisolated static func libraryName(_ item: JSONValue, language: AppLanguage, bundle: Bundle = .main) -> String {
        if let name = item["name"]?.string, !name.isEmpty { return name }
        if let key = item["nameKey"]?.string, !key.isEmpty {
            let name = text(key, language: language, bundle: bundle)
            if name != key { return name }
        }
        return item["targetFormat"]?.string?.uppercased() ?? item["nameKey"]?.string ?? ""
    }
}

@MainActor
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Localization.text(key, language: Localization.shared.language)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: Locale(identifier: Localization.shared.language.rawValue), arguments: arguments)
}
