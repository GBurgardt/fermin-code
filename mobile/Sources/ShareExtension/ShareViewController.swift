import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private struct SharedTweetPayload {
        let tweetURL: String
        let initialTweetText: String
    }

    private enum ShareBootstrapError: LocalizedError {
        case noInput
        case unsupportedContent
        case modelContainerSetupFailed
        case cannotPrepareVoiceHandoff

        var errorDescription: String? {
            switch self {
            case .noInput:
                return "No content was shared."
            case .unsupportedContent:
                return "Share a post from X/Twitter to generate a reply."
            case .modelContainerSetupFailed:
                return "Could not prepare local storage for this share."
            case .cannotPrepareVoiceHandoff:
                return "Could not hand off voice to the app."
            }
        }
    }

    private var hostingController: UIHostingController<AnyView>?
    private let jobSyncStore = TweetGenerationSyncStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.97, green: 0.94, blue: 0.90, alpha: 1.0)
        LoggingService.logToFile(level: .info, message: "[Share] Share extension boot")

        Task { @MainActor in
            await bootstrap()
        }
    }

    @MainActor
    private func bootstrap() async {
        do {
            let payload = try await extractSharedTweetPayload()
            let container = try Self.makeModelContainer()

            let root = ShareTweetGeneratorView(
                tweetURL: payload.tweetURL,
                initialTweetText: payload.initialTweetText,
                onRequestVoiceRedirect: { [weak self] payload in
                    guard let self else { throw ShareBootstrapError.cannotPrepareVoiceHandoff }
                    try self.prepareVoiceHandoff(payload)
                },
                onClose: { [weak self] in
                    self?.finish()
                }
            )
            .modelContainer(container)
            .environmentObject(jobSyncStore)
            .onAppear { [self] in
                self.jobSyncStore.start()
            }

            mount(rootView: AnyView(root))
            LoggingService.logToFile(level: .info, message: "[Share] Loaded tweet generator for URL: \(payload.tweetURL)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            LoggingService.logToFile(level: .error, message: "[Share] Bootstrap failed: \(message)")
            mount(rootView: AnyView(ShareBootstrapErrorView(message: message, closeAction: { [weak self] in
                self?.finish()
            })))
        }
    }

    private func mount(rootView: AnyView) {
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()

        let controller = UIHostingController(rootView: rootView)
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)

        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.didMove(toParent: self)
        hostingController = controller
    }

    private func finish() {
        LoggingService.logToFile(level: .info, message: "[Share] Closing extension")
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    @MainActor
    private func prepareVoiceHandoff(_ payload: ShareTweetGeneratorView.VoiceRedirectPayload) throws {
        do {
            try TweetPendingComposeStore.save(
                tweetURL: payload.tweetURL,
                initialTweetText: payload.initialTweetText,
                preferVoiceInput: true
            )
            LoggingService.logToFile(level: .info, message: "[Share] Queued voice handoff for app launch")
        } catch {
            throw ShareBootstrapError.cannotPrepareVoiceHandoff
        }
    }

    private static func makeModelContainer() throws -> ModelContainer {
        do {
            return try TweetGeneratorModelStore.makeSharedModelContainer()
        } catch {
            LoggingService.logToFile(level: .error, message: "[Share] ModelContainer creation failed: \(error)")
            throw ShareBootstrapError.modelContainerSetupFailed
        }
    }

    private func extractSharedTweetPayload() async throws -> SharedTweetPayload {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            throw ShareBootstrapError.noInput
        }

        var extractedTweetURL: String?
        var candidateTexts: [String] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await loadURLRepresentation(provider: provider),
                   let tweetURL = extractTweetURL(from: url.absoluteString) {
                    extractedTweetURL = tweetURL
                    continue
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await loadTextRepresentation(provider: provider, typeIdentifier: UTType.plainText.identifier) {
                    candidateTexts.append(text)
                    if extractedTweetURL == nil, let tweetURL = extractTweetURL(from: text) {
                        extractedTweetURL = tweetURL
                    }
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                   let text = try? await loadTextRepresentation(provider: provider, typeIdentifier: UTType.text.identifier) {
                    candidateTexts.append(text)
                    if extractedTweetURL == nil, let tweetURL = extractTweetURL(from: text) {
                        extractedTweetURL = tweetURL
                    }
                }
            }
        }

        guard let tweetURL = extractedTweetURL else {
            throw ShareBootstrapError.unsupportedContent
        }

        let initialTweetText = findInitialTweetText(in: candidateTexts, tweetURL: tweetURL)
        return SharedTweetPayload(tweetURL: tweetURL, initialTweetText: initialTweetText)
    }

    private func findInitialTweetText(in texts: [String], tweetURL: String) -> String {
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let withoutURL = trimmed.replacingOccurrences(of: tweetURL, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if withoutURL.count > 20 {
                return withoutURL
            }
        }
        return ""
    }

    private func extractTweetURL(from text: String) -> String? {
        let pattern = "(https?://(x|twitter)\\.com/[^\\s]+/status/\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let urlRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[urlRange])
    }

    private func loadURLRepresentation(provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let text = item as? String, let url = URL(string: text) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(throwing: ShareBootstrapError.unsupportedContent)
            }
        }
    }

    private func loadTextRepresentation(provider: NSItemProvider, typeIdentifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let text = item as? String {
                    continuation.resume(returning: text)
                    return
                }
                if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                    return
                }
                continuation.resume(returning: "")
            }
        }
    }
}

private struct ShareBootstrapErrorView: View {
    let message: String
    let closeAction: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.97, blue: 0.94),
                    Color(red: 0.97, green: 0.94, blue: 0.90),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(red: 0.66, green: 0.25, blue: 0.20))

                Text("Cannot Start KyCode")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Close", action: closeAction)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.82), in: Capsule())
            }
            .padding(24)
        }
    }
}
