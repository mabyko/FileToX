import Foundation

public final class FileNameFilter {
    private let patterns: [NSRegularExpression]
    private init(_ patterns: [NSRegularExpression]) { self.patterns = patterns }
    public static let all = FileNameFilter([])
    public static func normalize(_ typed: String?) -> String? {
        guard let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if isRegex(text) || text.contains("*") || text.contains("?") { return text }
        let ext = String(text.drop(while: { $0 == "." }))
        if !ext.isEmpty && !ext.contains(".") && FormatRegistry.find(extension: ext) != nil { return "*." + ext.lowercased() }
        return "*" + text + "*"
    }
    public static func validate(_ pattern: String) -> String? { OutputPathResolver.renameError(expression(pattern)) }
    public static func of(_ patterns: [String]?) -> FileNameFilter { FileNameFilter((patterns ?? []).compactMap { try? NSRegularExpression(pattern: expression($0), options: .caseInsensitive) }) }
    public func matches(_ name: String) -> Bool { patterns.isEmpty || patterns.contains { !(EngineRegex.matches($0, name) ?? []).isEmpty } }
    private static func isRegex(_ p: String) -> Bool { p.count > 2 && p.hasPrefix("/") && p.hasSuffix("/") }
    private static func expression(_ p: String) -> String {
        if isRegex(p) { return String(p.dropFirst().dropLast()) }
        return "^" + p.trimmingCharacters(in: .whitespacesAndNewlines).map { $0 == "*" ? ".*" : $0 == "?" ? "." : NSRegularExpression.escapedPattern(for: String($0)) }.joined() + "$"
    }
}
