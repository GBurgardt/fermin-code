import Foundation

enum TweetConversationReadStore {
    private static let keyPrefix = "TweetConversation.LastSeenVersion."

    static func markSeen(conversationID: UUID, versionID: UUID) {
        defaults()?.set(versionID.uuidString, forKey: keyPrefix + conversationID.uuidString)
    }

    static func lastSeenVersionID(for conversationID: UUID) -> UUID? {
        guard let raw = defaults()?.string(forKey: keyPrefix + conversationID.uuidString) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    static func isUnread(conversation: TweetConversation) -> Bool {
        guard let latestVersionID = conversation.latestVersion?.id else { return false }
        return lastSeenVersionID(for: conversation.id) != latestVersionID
    }

    private static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: SharedInbox.appGroupId)
    }
}
