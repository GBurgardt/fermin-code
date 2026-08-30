import Foundation

enum XMLExtractor {
    static func extractAllTagContents(from source: String, tag: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(tag)[^>]*>(.*?)</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[capture])
        }
    }

    static func extractTagLenient(from source: String, tag: String) -> String {
        guard let openRange = matchRange(pattern: "<\(tag)[^>]*>", in: source) else {
            return ""
        }
        let startIndex = openRange.upperBound
        if let closeRange = matchRange(pattern: "</\(tag)>", in: source, start: startIndex) {
            return String(source[startIndex..<closeRange.lowerBound])
        }
        return String(source[startIndex...])
    }

    static func extractTagPartial(from source: String, tag: String) -> String {
        guard let openRange = matchRange(pattern: "<\(tag)[^>]*>", in: source) else {
            return ""
        }
        let startIndex = openRange.upperBound
        if let closeRange = matchRange(pattern: "</\(tag)>", in: source, start: startIndex) {
            return String(source[startIndex..<closeRange.lowerBound])
        }
        return String(source[startIndex...])
    }

    static func decodeEntities(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func stripCdata(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text
            .replacingOccurrences(of: "<![CDATA[", with: "")
            .replacingOccurrences(of: "]]>", with: "")
    }

    private static func matchRange(pattern: String, in source: String, start: String.Index? = nil) -> Range<String.Index>? {
        let startIndex = start ?? source.startIndex
        let nsRange = NSRange(startIndex..<source.endIndex, in: source)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        guard let match = regex.firstMatch(in: source, options: [], range: nsRange) else {
            return nil
        }
        return Range(match.range, in: source)
    }
}
