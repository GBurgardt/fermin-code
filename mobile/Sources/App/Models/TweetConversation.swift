import Foundation
import SwiftData

@Model
final class TweetConversation {
    var id: UUID
    var sourceTweetURL: String
    var sourceTweetText: String
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var lastModeRawValue: String
    var lastIntention: String?

    @Relationship(deleteRule: .cascade, inverse: \TweetVersion.conversation)
    var versions: [TweetVersion]?

    init(
        id: UUID = UUID(),
        sourceTweetURL: String,
        sourceTweetText: String,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastModeRawValue: String = "reply",
        lastIntention: String? = nil
    ) {
        self.id = id
        self.sourceTweetURL = sourceTweetURL
        self.sourceTweetText = sourceTweetText
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastModeRawValue = lastModeRawValue
        self.lastIntention = lastIntention
    }
}

@Model
final class TweetVersion {
    var id: UUID
    var createdAt: Date
    var modeRawValue: String
    var intention: String?
    var feedback: String?
    var modelRawValue: String?
    var usedFullThread: Bool
    var sourceTweetTextSnapshot: String
    var contentES: String
    var contentEN: String

    var conversation: TweetConversation?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        modeRawValue: String,
        intention: String? = nil,
        feedback: String? = nil,
        modelRawValue: String? = nil,
        usedFullThread: Bool,
        sourceTweetTextSnapshot: String,
        contentES: String,
        contentEN: String,
        conversation: TweetConversation? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modeRawValue = modeRawValue
        self.intention = intention
        self.feedback = feedback
        self.modelRawValue = modelRawValue
        self.usedFullThread = usedFullThread
        self.sourceTweetTextSnapshot = sourceTweetTextSnapshot
        self.contentES = contentES
        self.contentEN = contentEN
        self.conversation = conversation
    }
}

extension TweetConversation {
    var sortedVersionsAscending: [TweetVersion] {
        (versions ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var sortedVersionsDescending: [TweetVersion] {
        (versions ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    var latestVersion: TweetVersion? {
        sortedVersionsDescending.first
    }

    var versionsCount: Int {
        versions?.count ?? 0
    }

    var sourcePreview: String {
        let text = sourceTweetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return sourceTweetURL
        }
        return text
    }

    var formattedUpdatedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: updatedAt, relativeTo: Date())
    }
}
