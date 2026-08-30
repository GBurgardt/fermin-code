import Foundation

enum TweetSourceLink {
    static func normalizedTweetURL(from rawValue: String?) -> String? {
        guard let extracted = extractURLString(from: rawValue) else { return nil }
        return canonicalTweetURL(from: extracted)
    }

    private static func extractURLString(from rawValue: String?) -> String? {
        guard var rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        if rawValue.hasPrefix("x.com/") || rawValue.hasPrefix("twitter.com/") {
            rawValue = "https://" + rawValue
        } else if rawValue.hasPrefix("www.x.com/") || rawValue.hasPrefix("www.twitter.com/") {
            rawValue = "https://" + rawValue
        }

        if let url = URL(string: rawValue), url.scheme != nil {
            return url.absoluteString
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        guard let match = detector?.firstMatch(in: rawValue, options: [], range: range) else {
            return nil
        }

        if let url = match.url {
            return url.absoluteString
        }

        guard let matchRange = Range(match.range, in: rawValue) else { return nil }
        return String(rawValue[matchRange])
    }

    private static func canonicalTweetURL(from rawValue: String) -> String? {
        guard let url = URL(string: rawValue),
              let host = normalizedHost(from: url.host) else {
            return nil
        }

        guard host == "x.com" || host == "twitter.com" else { return nil }

        let pathComponents = url.path
            .split(separator: "/")
            .map(String.init)

        guard let statusIndex = pathComponents.firstIndex(of: "status"),
              statusIndex + 1 < pathComponents.count else {
            return nil
        }

        let statusID = pathComponents[statusIndex + 1]
        guard !statusID.isEmpty, statusID.allSatisfy(\.isNumber) else { return nil }

        let canonicalPath = "/" + pathComponents[0...statusIndex + 1].joined(separator: "/")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "x.com"
        components.path = canonicalPath
        return components.url?.absoluteString
    }

    private static func normalizedHost(from host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        let suffix = parts.suffix(2).joined(separator: ".")
        if suffix == "x.com" || suffix == "twitter.com" {
            return suffix
        }
        return host
    }
}
