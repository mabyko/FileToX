import Foundation

public final class Localizer: ILocalizer {
    public static let languages = ["en", "ko", "ja", "zh-CN"]
    private let english: [String: String]
    private var current: [String: String]
    public private(set) var language: String
    public var languageChanged: (() -> Void)?
    public init(_ language: String?) {
        english = Self.load("en"); self.language = Self.resolve(language)
        current = self.language == "en" ? english : Self.load(self.language)
    }
    public subscript(key: String) -> String { current[key] ?? english[key] ?? key }
    public func has(_ key: String) -> Bool { current[key] != nil || english[key] != nil }
    public func format(_ key: String, _ arguments: String...) -> String {
        let original = self[key], chars = Array(original)
        var result = "", i = 0
        while i < chars.count {
            if (chars[i] == "{" || chars[i] == "}"), i + 1 < chars.count, chars[i + 1] == chars[i] { result.append(chars[i]); i += 2; continue }
            if chars[i] == "}" { return original }
            if chars[i] != "{" { result.append(chars[i]); i += 1; continue }
            guard let end = chars[(i + 1)...].firstIndex(of: "}") else { return original }
            let field = String(chars[(i + 1)..<end]), parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0].split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let index = Int(parts[0].trimmingCharacters(in: .whitespaces)), index >= 0, index < arguments.count else { return original }
            var value = arguments[index]
            if parts.count == 2 {
                guard let width = Int(parts[1].trimmingCharacters(in: .whitespaces)), width != Int.min, abs(width) <= 1_000_000 else { return original }
                let padding = String(repeating: " ", count: max(0, abs(width) - value.utf16.count))
                value = width < 0 ? value + padding : padding + value
            }
            result += value; i = end + 1
        }
        return result
    }

    public func setLanguage(_ language: String?) { let resolved = Self.resolve(language); if resolved == self.language { return }; self.language = resolved; current = resolved == "en" ? english : Self.load(resolved); languageChanged?() }
    public static func resolve(_ language: String?) -> String {
        let code = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if code == "ko" || code.hasPrefix("ko-") { return "ko" }
        if code == "ja" || code == "ja-jp" { return "ja" }
        if code == "zh" || code.hasPrefix("zh-") { return "zh-CN" }
        return "en"
    }
    private static func load(_ language: String) -> [String: String] {
        var values: [String: String] = ResourceBundle.data(language, "json", subdirectory: "i18n").flatMap { try? FileeJson.decode([String: String].self, from: $0) } ?? [:]
        let extras = ResourceBundle.data(language + ".extras", "json", subdirectory: "i18n").flatMap { try? FileeJson.decode([String: String].self, from: $0) } ?? [:]
        values.merge(extras) { _, new in new }; return values
    }
}
