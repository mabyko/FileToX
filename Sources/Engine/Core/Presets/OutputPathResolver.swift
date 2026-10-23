import Foundation

public enum OutputPathResolver {
    public struct Tokens {
        public var sourcePath: String; public var presetName: String; public var index: Int; public var now: Date
        public init(_ sourcePath: String, _ presetName: String, _ index: Int, _ now: Date = Date()) { self.sourcePath = sourcePath; self.presetName = presetName; self.index = index; self.now = now }
    }
    public static func resolve(_ rule: OutputRule, _ tokens: Tokens, _ targetExtension: String, exists: (String) -> Bool, suffix: String? = nil) -> String? {
        let sourceDir = FilePath.directoryName(FilePath.fullPath(tokens.sourcePath)) ?? ""
        let dir: String
        switch rule.location {
        case .subfolder: dir = FilePath.combine(sourceDir, sanitize(expandPattern(rule.subfolderName, tokens), fallback: "converted"))
        case .customFolder where !rule.customFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: dir = rule.customFolder
        default: dir = sourceDir
        }
        let name = sanitize(rename(expandPattern(rule.fileNamePattern, tokens), rule.renames), fallback: FormatRegistry.nameWithoutExtension(tokens.sourcePath)) + (suffix ?? "")
        let ext = String(targetExtension.drop(while: { $0 == "." }))
        func path(_ base: String) -> String { FilePath.combine(dir, base + (ext.isEmpty ? "" : "." + ext)) }
        func source(_ p: String) -> Bool { FilePath.fullPath(p).caseInsensitiveCompare(FilePath.fullPath(tokens.sourcePath)) == .orderedSame }
        var candidate = path(name)
        if !source(candidate) {
            if !exists(candidate) || rule.conflict == .overwrite { return candidate }
            if rule.conflict == .skip { return nil }
        }
        var n = 2
        while true { candidate = path("\(name) (\(n))"); if !exists(candidate) && !source(candidate) { return candidate }; n += 1 }
    }
    public static func rename(_ name: String, _ steps: [RenameStep]) -> String { steps.reduce(name) { $1.apply($0) } }
    public static func rename(_ name: String, _ find: String?, _ replace: String?) -> String {
        guard let find, !find.isEmpty, let regex = try? NSRegularExpression(pattern: find) else { return name }
        let matches = EngineRegex.matches(regex, name)
        guard let matches else { return name }
        let input = name as NSString
        var result = "", start = 0
        for match in matches {
            result += input.substring(with: NSRange(location: start, length: match.range.location - start))
            result += EngineRegex.replacement(replace ?? "", match, name, regex)
            start = NSMaxRange(match.range)
        }
        return result + input.substring(from: start)
    }
    public static func renameError(_ find: String?) -> String? {
        guard let find, !find.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: find); return nil } catch { return error.localizedDescription }
    }
    public static func expandPattern(_ pattern: String, _ tokens: Tokens) -> String {
        var pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{name}" : pattern
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd"; let date = formatter.string(from: tokens.now)
        formatter.dateFormat = "HHmmss"; let time = formatter.string(from: tokens.now)
        for (key, value) in [("name", FormatRegistry.nameWithoutExtension(tokens.sourcePath)), ("ext", FormatRegistry.extensionOf(tokens.sourcePath)), ("preset", tokens.presetName), ("date", date), ("time", time), ("index", String(tokens.index))] { pattern = pattern.replacingOccurrences(of: "{\(key)}", with: value, options: .caseInsensitive) }
        return pattern
    }
    public static func sanitize(_ name: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*\0")
        var result = String(String.UnicodeScalarView(name.unicodeScalars.map { (invalid.contains($0) || $0.properties.generalCategory == .control) ? UnicodeScalar(95)! : $0 })).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") { result.removeLast() }
        return result.isEmpty ? fallback : result
    }
}

public extension RenameStep {
    func apply(_ name: String) -> String {
        if isBlank { return name }
        func fixed(_ pattern: String, _ replacement: String = "") -> String { OutputPathResolver.rename(name, pattern, replacement) }
        switch kind {
        case .replace: return name.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
        case .remove: return name.replacingOccurrences(of: find, with: "", options: .caseInsensitive)
        case .prefix: return replace + name
        case .suffix: return name + replace
        case .spacesToUnderscores: return fixed(#"\s+"#, "_")
        case .removeCopyNumber: return fixed(#"\s*\(\d+\)$"#)
        case .removeBrackets: return fixed(#"\s*(\([^)]*\)|\[[^\]]*\]|\{[^}]*\})"#).trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeLeadingNumber: return fixed(#"^\d+[\s._-]*"#)
        case .removeSymbols: return fixed(#"[^\p{L}\p{N}\s._-]"#)
        case .lowercase: return name.lowercased()
        case .uppercase: return name.uppercased()
        case .regex: return OutputPathResolver.rename(name, find, replace)
        }
    }
}

/// ICU's progress callback bounds matching, including catastrophic backtracking, without leaving runaway threads.
enum EngineRegex {
    static func matches(_ regex: NSRegularExpression, _ name: String) -> [NSTextCheckingResult]? {
        let deadline = Date().addingTimeInterval(0.25)
        var matches: [NSTextCheckingResult] = [], timedOut = false
        regex.enumerateMatches(in: name, options: .reportProgress, range: NSRange(location: 0, length: name.utf16.count)) { match, _, stop in
            if Date() >= deadline { timedOut = true; stop.pointee = true }
            else if let match { matches.append(match) }
        }
        return timedOut ? nil : matches
    }
    // .NET numbers unnamed captures first and named captures last; ICU numbers them in opening-parenthesis order.
    private static func captureIndices(_ regex: NSRegularExpression) -> [Int] {
        let chars = Array(regex.pattern)
        var unnamed: [Int] = [], named: [Int] = [], index = 0, capture = 0, inClass = false
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\" { index += 2; continue }
            if inClass { if ch == "]" { inClass = false }; index += 1; continue }
            if ch == "[" { inClass = true; index += 1; continue }
            if ch == "(" {
                if index + 2 < chars.count && chars[index + 1] == "?" && chars[index + 2] == "#" {
                    index += 3
                    while index < chars.count && chars[index] != ")" { index += 1 }
                } else if index + 1 >= chars.count || chars[index + 1] != "?" { capture += 1; unnamed.append(capture) }
                else if index + 3 < chars.count && chars[index + 2] == "<" && chars[index + 3] != "=" && chars[index + 3] != "!" { capture += 1; named.append(capture) }
            }
            index += 1
        }
        return capture == regex.numberOfCaptureGroups ? [0] + unnamed + named : Array(0...regex.numberOfCaptureGroups)
    }
    static func replacement(_ template: String, _ match: NSTextCheckingResult, _ input: String, _ regex: NSRegularExpression) -> String {
        let text = input as NSString, chars = Array(template), captures = captureIndices(regex)
        func group(_ n: Int) -> String {
            guard n < captures.count, captures[n] < match.numberOfRanges else { return "" }
            let range = match.range(at: captures[n])
            return range.location != NSNotFound ? text.substring(with: range) : ""
        }
        var result = "", i = 0
        while i < chars.count {
            guard chars[i] == "$", i + 1 < chars.count else { result.append(chars[i]); i += 1; continue }
            let next = chars[i + 1]
            switch next {
            case "$": result += "$"; i += 2
            case "&": result += group(0); i += 2
            case "`": result += text.substring(to: match.range.location); i += 2
            case "'": result += text.substring(from: NSMaxRange(match.range)); i += 2
            case "_": result += input; i += 2
            case "+": result += group(max(0, match.numberOfRanges - 1)); i += 2
            case "{":
                guard let end = chars[(i + 2)...].firstIndex(of: "}") else { result += "$"; i += 1; continue }
                let key = String(chars[(i + 2)..<end])
                if let n = Int(key), n < match.numberOfRanges { result += group(n); i = end + 1 }
                else if regex.pattern.contains("(?<" + key + ">") {
                    let range = match.range(withName: key); if range.location != NSNotFound { result += text.substring(with: range) }; i = end + 1
                } else { result += "$"; i += 1 }
            default:
                var end = i + 1
                while end < chars.count && chars[end].isASCII && chars[end].isNumber { end += 1 }
                if end > i + 1, let n = Int(String(chars[(i + 1)..<end])), n < match.numberOfRanges { result += group(n); i = end }
                else { result += "$"; i += 1 }
            }
        }
        return result
    }
}
