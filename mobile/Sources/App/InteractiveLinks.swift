import Foundation

enum KycodeInteractiveLink {
    static func webURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.lowercased().hasPrefix("www.")
            ? "https://\(trimmed)"
            : trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    /// Turns visible bare web addresses into Markdown links. Existing Markdown
    /// destinations, autolinks and inline-code spans remain untouched.
    static func autolinkBareWebURLs(in source: String) -> String {
        guard !source.isEmpty,
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue
              ) else {
            return source
        }

        let sourceNSString = source as NSString
        let matches = detector.matches(
            in: source,
            range: NSRange(location: 0, length: sourceNSString.length)
        )
        var result = source

        for match in matches.reversed() {
            guard let detectedURL = match.url,
                  webURL(from: detectedURL.absoluteString) != nil else {
                continue
            }

            let matchedText = sourceNSString.substring(with: match.range)
            guard webURL(from: matchedText) != nil else { continue }

            let prefix = sourceNSString.substring(
                with: NSRange(location: 0, length: match.range.location)
            )
            if isInsideInlineCode(prefix) { continue }

            let precedingCharacter: String? = match.range.location > 0
                ? sourceNSString.substring(
                    with: NSRange(location: match.range.location - 1, length: 1)
                )
                : nil
            if precedingCharacter == "(" || precedingCharacter == "<" {
                continue
            }

            let replacement: String
            if matchedText.lowercased().hasPrefix("www.") {
                replacement = "[\(matchedText)](https://\(matchedText))"
            } else {
                replacement = "<\(matchedText)>"
            }

            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }

    private static func isInsideInlineCode(_ prefix: String) -> Bool {
        var delimiterCount = 0
        var escaped = false
        for character in prefix {
            if character == "\\" && !escaped {
                escaped = true
                continue
            }
            if character == "`" && !escaped {
                delimiterCount += 1
            }
            escaped = false
        }
        return delimiterCount.isMultiple(of: 2) == false
    }
}
