import Foundation

enum TweetClipboardIntakeStore {
    private static let evaluatedChangeCountKey = "tweet.clipboard.lastEvaluatedChangeCount"
    private static let importedTweetURLKey = "tweet.clipboard.lastImportedTweetURL"

    static func shouldEvaluate(changeCount: Int) -> Bool {
        lastEvaluatedChangeCount() != changeCount
    }

    static func markEvaluated(changeCount: Int, importedTweetURL: String? = nil) {
        defaults()?.set(changeCount, forKey: evaluatedChangeCountKey)
        if let importedTweetURL {
            defaults()?.set(importedTweetURL, forKey: importedTweetURLKey)
        }
    }

    static func lastImportedTweetURL() -> String? {
        defaults()?.string(forKey: importedTweetURLKey)
    }

    private static func lastEvaluatedChangeCount() -> Int {
        defaults()?.integer(forKey: evaluatedChangeCountKey) ?? 0
    }

    private static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: SharedInbox.appGroupId)
    }
}
