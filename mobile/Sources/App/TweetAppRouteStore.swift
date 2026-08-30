import Foundation
import UIKit

@MainActor
final class TweetAppRouteStore: ObservableObject {
    static let shared = TweetAppRouteStore()

    @Published private(set) var pendingConversationID: UUID?
    @Published var presentedComposer: TweetComposerPresentation?

    private var pendingComposePollingTask: Task<Void, Never>?
    private var clipboardScanTask: Task<Void, Never>?

    private init() { }

    func presentConversation(_ conversation: TweetConversation) {
        pendingConversationID = nil
        if let latestVersionID = conversation.latestVersion?.id {
            TweetConversationReadStore.markSeen(conversationID: conversation.id, versionID: latestVersionID)
        }
        presentComposer(
            tweetURL: conversation.sourceTweetURL,
            initialTweetText: conversation.sourceTweetText,
            conversationID: conversation.id
        )
    }

    func dismissComposer() {
        pendingComposePollingTask?.cancel()
        presentedComposer = nil
    }

    func requestConversationOpen(id: UUID) {
        pendingConversationID = id
    }

    func handle(url: URL) {
        if let payload = TweetComposeDeepLink.payload(from: url) {
            LoggingService.logToFile(level: .info, message: "[RouteStore] Handling compose deep link")
            presentComposer(
                tweetURL: payload.tweetURL,
                initialTweetText: payload.initialTweetText
            )
            return
        }

        guard url.scheme?.lowercased() == "kycode" else { return }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if url.host?.lowercased() == "conversation",
           let idString = pathComponents.first,
           let id = UUID(uuidString: idString) {
            requestConversationOpen(id: id)
        }
    }

    func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) {
        guard let url = TweetGenerationNotifications.deepLink(from: userInfo) else { return }
        handle(url: url)
    }

    func consumePendingComposeRequestIfNeeded() {
        LoggingService.logToFile(level: .debug, message: "[RouteStore] Checking pending compose request")
        guard presentedComposer == nil else { return }
        guard let request = TweetPendingComposeStore.consume() else { return }

        presentComposer(
            tweetURL: request.tweetURL,
            initialTweetText: request.initialTweetText
        )
    }

    func startPendingComposePolling() {
        pendingComposePollingTask?.cancel()
        pendingComposePollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.consumePendingComposeRequestIfNeeded()
            guard self.presentedComposer == nil else { return }

            for delay in [250_000_000, 750_000_000, 1_500_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                guard !Task.isCancelled else { return }
                self.consumePendingComposeRequestIfNeeded()
                if self.presentedComposer != nil {
                    return
                }
            }
        }
    }

    func refreshClipboardImportIfNeeded() {
        clipboardScanTask?.cancel()
        clipboardScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.autoImportTweetFromClipboardIfNeeded()
        }
    }

    func importTweetFromPasteboardManually() {
        clipboardScanTask?.cancel()
        clipboardScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.importTweetFromPasteboardString(UIPasteboard.general.string)
        }
    }

    func importTweetFromPastedStrings(_ pastedStrings: [String]) {
        guard let firstMatch = pastedStrings.first(where: { TweetSourceLink.normalizedTweetURL(from: $0) != nil }) else {
            return
        }
        importTweetFromPasteboardString(firstMatch)
    }

    private func presentComposer(
        tweetURL: String,
        initialTweetText: String,
        conversationID: UUID? = nil
    ) {
        pendingComposePollingTask?.cancel()
        pendingConversationID = nil
        LoggingService.logToFile(level: .info, message: "[RouteStore] Presenting composer for \(tweetURL)")
        presentedComposer = TweetComposerPresentation(
            conversationID: conversationID,
            tweetURL: tweetURL,
            initialTweetText: initialTweetText
        )
    }

    private func autoImportTweetFromClipboardIfNeeded() async {
        guard presentedComposer == nil else { return }
        guard !TweetPendingComposeStore.hasPendingRequest() else { return }

        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        guard TweetClipboardIntakeStore.shouldEvaluate(changeCount: changeCount) else { return }

        do {
            let detectedValues = try await pasteboard.detectedValues(for: [\UIPasteboard.DetectedValues.probableWebURL])
            guard let normalizedTweetURL = TweetSourceLink.normalizedTweetURL(from: detectedValues.probableWebURL) else {
                TweetClipboardIntakeStore.markEvaluated(changeCount: changeCount)
                return
            }

            TweetClipboardIntakeStore.markEvaluated(changeCount: changeCount, importedTweetURL: normalizedTweetURL)
            LoggingService.logToFile(level: .info, message: "[RouteStore] Auto-importing copied tweet \(normalizedTweetURL)")
            presentComposer(tweetURL: normalizedTweetURL, initialTweetText: "")
        } catch {
            LoggingService.logToFile(level: .error, message: "[RouteStore] Clipboard detection failed: \(error)")
        }
    }

    private func importTweetFromPasteboardString(_ rawValue: String?) {
        guard presentedComposer == nil else { return }
        guard let normalizedTweetURL = TweetSourceLink.normalizedTweetURL(from: rawValue) else {
            LoggingService.logToFile(level: .debug, message: "[RouteStore] Pasteboard did not contain a tweet URL")
            return
        }

        let changeCount = UIPasteboard.general.changeCount
        TweetClipboardIntakeStore.markEvaluated(changeCount: changeCount, importedTweetURL: normalizedTweetURL)
        LoggingService.logToFile(level: .info, message: "[RouteStore] Importing pasted tweet \(normalizedTweetURL)")
        presentComposer(tweetURL: normalizedTweetURL, initialTweetText: "")
    }
}

struct TweetComposerPresentation: Identifiable {
    let id = UUID()
    let conversationID: UUID?
    let tweetURL: String
    let initialTweetText: String
}
