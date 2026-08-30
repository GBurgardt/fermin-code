import Foundation

enum TweetPendingComposeStore {
    struct Request: Codable {
        let tweetURL: String
        let initialTweetText: String
        let preferVoiceInput: Bool
        let createdAt: Date
    }

    private static let defaultsKey = "tweet.pending-compose-request"
    private static let fileName = "tweet-pending-compose.json"

    static func save(tweetURL: String, initialTweetText: String, preferVoiceInput: Bool) throws {
        let normalizedTweetURL = tweetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTweetURL.isEmpty else {
            throw NSError(domain: "TweetPendingComposeStore", code: 1)
        }

        guard let fileURL = fileURL() else {
            LoggingService.logToFile(level: .error, message: "[PendingCompose] Missing app-group container while saving")
            throw NSError(domain: "TweetPendingComposeStore", code: 2)
        }

        let request = Request(
            tweetURL: normalizedTweetURL,
            initialTweetText: initialTweetText.trimmingCharacters(in: .whitespacesAndNewlines),
            preferVoiceInput: preferVoiceInput,
            createdAt: Date()
        )

        let data = try JSONEncoder().encode(request)
        try data.write(to: fileURL, options: .atomic)
        legacyDefaults()?.removeObject(forKey: defaultsKey)
        legacyDefaults()?.synchronize()
        LoggingService.logToFile(
            level: .info,
            message: "[PendingCompose] Saved request for \(normalizedTweetURL)"
        )
    }

    static func consume() -> Request? {
        if let fileURL = fileURL(),
           let data = try? Data(contentsOf: fileURL),
           let request = try? JSONDecoder().decode(Request.self, from: data) {
            try? FileManager.default.removeItem(at: fileURL)
            LoggingService.logToFile(
                level: .info,
                message: "[PendingCompose] Consumed request for \(request.tweetURL)"
            )
            return request
        }

        if let defaults = legacyDefaults() {
            defaults.synchronize()
            if let data = defaults.data(forKey: defaultsKey),
               let request = try? JSONDecoder().decode(Request.self, from: data) {
                defaults.removeObject(forKey: defaultsKey)
                defaults.synchronize()
                LoggingService.logToFile(
                    level: .info,
                    message: "[PendingCompose] Consumed legacy defaults request for \(request.tweetURL)"
                )
                return request
            }
        }

        LoggingService.logToFile(level: .debug, message: "[PendingCompose] No pending request found")
        return nil
    }

    static func hasPendingRequest() -> Bool {
        if let fileURL = fileURL(), FileManager.default.fileExists(atPath: fileURL.path) {
            return true
        }

        guard let defaults = legacyDefaults() else { return false }
        defaults.synchronize()
        return defaults.data(forKey: defaultsKey) != nil
    }

    static func clear() {
        if let fileURL = fileURL() {
            try? FileManager.default.removeItem(at: fileURL)
        }
        legacyDefaults()?.removeObject(forKey: defaultsKey)
        legacyDefaults()?.synchronize()
    }

    private static func fileURL() -> URL? {
        SharedInbox.containerURL()?.appendingPathComponent(fileName)
    }

    private static func legacyDefaults() -> UserDefaults? {
        UserDefaults(suiteName: SharedInbox.appGroupId)
    }
}
