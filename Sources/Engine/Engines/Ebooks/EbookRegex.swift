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
        let found = matches(pattern, text, options)
        if found.isEmpty { return text }
        // Evaluate replacements in input order (resource numbering and linked aids depend on it) and assemble the
        // result in one forward pass: in-place NSMutableString edits were quadratic on multi-megabyte documents.
        let source = text as NSString
        let output = NSMutableString(capacity: source.length)
        var position = 0
        for match in found {
            let range = match.range
            if range.location > position { output.append(source.substring(with: NSRange(location: position, length: range.location - position))) }
            output.append(try replacement(match))
            position = range.location + range.length
        }
        if position < source.length { output.append(source.substring(from: position)) }
        return output as String
    }
}
