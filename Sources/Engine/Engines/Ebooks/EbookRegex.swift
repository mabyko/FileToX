import Foundation

// The e-book ports use .NET regex captures and UTF-16 offsets.
enum EbookRegex {
    static func matches(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    static func group(_ match: NSTextCheckingResult, _ text: String, _ index: Int = 0) -> String {
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
    }
    static func replace(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = [], _ replacement: (NSTextCheckingResult) throws -> String) rethrows -> String {
        let output = NSMutableString(string: text)
        // Evaluate replacements in input order (resource numbering and linked aids depend on it).
        var replacements: [(NSRange, String)] = []
        for match in matches(pattern, text, options) { replacements.append((match.range, try replacement(match))) }
        for (range, value) in replacements.reversed() { output.replaceCharacters(in: range, with: value) }
        return output as String
    }
}
