import Foundation

struct TweetComposeDeepLink {
    struct Payload {
        let tweetURL: String
        let initialTweetText: String
        let preferVoiceInput: Bool
    }

    static let scheme = "kycode"
    private static let composeHost = "compose"
    private static let tweetURLQueryName = "tweet_url"
    private static let tweetTextQueryName = "tweet_text"
    private static let preferVoiceQueryName = "voice"

    static func makeURL(tweetURL: String, initialTweetText: String, preferVoiceInput: Bool) -> URL? {
        let normalizedTweetURL = tweetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTweetURL.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = composeHost

        var queryItems = [
            URLQueryItem(name: tweetURLQueryName, value: normalizedTweetURL),
            URLQueryItem(name: preferVoiceQueryName, value: preferVoiceInput ? "1" : "0")
        ]

        let normalizedTweetText = initialTweetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTweetText.isEmpty {
            queryItems.append(URLQueryItem(name: tweetTextQueryName, value: normalizedTweetText))
        }

        components.queryItems = queryItems
        return components.url
    }

    static func payload(from url: URL) -> Payload? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == composeHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let tweetURL = components.value(for: tweetURLQueryName)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !tweetURL.isEmpty else {
            return nil
        }

        let tweetText = components.value(for: tweetTextQueryName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferVoiceValue = components.value(for: preferVoiceQueryName)?.lowercased() ?? "0"
        let preferVoiceInput = preferVoiceValue == "1" || preferVoiceValue == "true" || preferVoiceValue == "yes"

        return Payload(
            tweetURL: tweetURL,
            initialTweetText: tweetText,
            preferVoiceInput: preferVoiceInput
        )
    }
}

private extension URLComponents {
    func value(for name: String) -> String? {
        queryItems?.first(where: { $0.name == name })?.value
    }
}
