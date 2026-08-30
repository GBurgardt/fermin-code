import Foundation
import UserNotifications

enum TweetGenerationNotifications {
    private static let deepLinkKey = "deepLink"

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    LoggingService.logToFile(level: .error, message: "[TweetNotifications] authorization failed: \(error)")
                    return
                }
                LoggingService.logToFile(level: .info, message: "[TweetNotifications] authorization granted=\(granted)")
            }
        }
    }

    static func scheduleSuccess(jobID: UUID, conversationID: UUID) {
        schedule(
            identifier: "tweet-generation-success-\(jobID.uuidString)",
            title: "Your tweet is ready",
            body: "Tap to open it in KyCode.",
            deepLink: deepLink(for: conversationID)
        )
    }

    static func scheduleFailure(jobID: UUID, conversationID: UUID?) {
        schedule(
            identifier: "tweet-generation-failure-\(jobID.uuidString)",
            title: "Tweet generation failed",
            body: "Tap to reopen and try again.",
            deepLink: conversationID.map(deepLink(for:))
        )
    }

    static func deepLink(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[deepLinkKey] as? String else { return nil }
        return URL(string: raw)
    }

    private static func deepLink(for conversationID: UUID) -> String {
        "kycode://conversation/\(conversationID.uuidString)"
    }

    private static func schedule(identifier: String, title: String, body: String, deepLink: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let deepLink {
            content.userInfo = [deepLinkKey: deepLink]
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                LoggingService.logToFile(level: .error, message: "[TweetNotifications] schedule failed: \(error)")
                return
            }
            LoggingService.logToFile(level: .info, message: "[TweetNotifications] scheduled id=\(identifier)")
        }
    }
}
