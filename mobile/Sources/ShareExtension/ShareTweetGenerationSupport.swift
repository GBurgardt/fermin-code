import Foundation

enum ShareTweetModel: String, CaseIterable, Identifiable {
    case claudeOpus
    case claudeSonnet

    private static let defaultsKey = "TweetGenerator.DefaultModel"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeOpus:
            return "Opus"
        case .claudeSonnet:
            return "Sonnet"
        }
    }

    var modelId: String {
        switch self {
        case .claudeOpus:
            return "claude-opus-4-6"
        case .claudeSonnet:
            return "claude-sonnet-4-5-20250929"
        }
    }

    var maxTokens: Int { 8192 }
    var temperature: Double { 1.0 }

    static func preferred() -> ShareTweetModel {
        let defaults = UserDefaults(suiteName: SharedInbox.appGroupId)
        guard let raw = defaults?.string(forKey: defaultsKey),
              let model = ShareTweetModel(rawValue: raw) else {
            return .claudeOpus
        }
        return model
    }

    func persistAsPreferred() {
        let defaults = UserDefaults(suiteName: SharedInbox.appGroupId)
        defaults?.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum ShareTweetGenerationError: LocalizedError {
    case missingSecrets
    case missingAnthropicKey
    case missingGroqKey
    case emptySourceTweet
    case emptyModelOutput
    case emptyTranscription
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingSecrets:
            return "Secrets.plist could not be found."
        case .missingAnthropicKey:
            return "ANTHROPIC_API_KEY is missing."
        case .missingGroqKey:
            return "GROQ_API_KEY is missing."
        case .emptySourceTweet:
            return "Tweet text could not be loaded."
        case .emptyModelOutput:
            return "Model returned an empty draft."
        case .emptyTranscription:
            return "Transcription came back empty."
        case .timedOut:
            return "The request timed out."
        }
    }
}

struct ShareSecrets {
    let anthropicApiKey: String
    let groqApiKey: String
    let tweetApiURL: String?
    let promptApiURL: URL?

    static func load() throws -> ShareSecrets {
        guard let dict = loadDictionary() else {
            throw ShareTweetGenerationError.missingSecrets
        }

        func required(_ key: String, error: ShareTweetGenerationError) throws -> String {
            guard let raw = dict[key] as? String else {
                throw error
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("YOUR_") {
                throw error
            }
            return trimmed
        }

        func optional(_ key: String) -> String? {
            guard let raw = dict[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("YOUR_") {
                return nil
            }
            return trimmed
        }

        return ShareSecrets(
            anthropicApiKey: try required("ANTHROPIC_API_KEY", error: .missingAnthropicKey),
            groqApiKey: try required("GROQ_API_KEY", error: .missingGroqKey),
            tweetApiURL: optional("TWEET_API_URL"),
            promptApiURL: resolvePromptApiURL(
                explicitURL: optional("PROMPT_API_URL"),
                tweetApiURL: optional("TWEET_API_URL")
            )
        )
    }

    private static func resolvePromptApiURL(explicitURL: String?, tweetApiURL: String?) -> URL? {
        if let explicitURL,
           let url = URL(string: explicitURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }

        if let tweetApiURL,
           let tweetURL = URL(string: tweetApiURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           var components = URLComponents(url: tweetURL, resolvingAgainstBaseURL: false) {
            components.path = "/api/tweet-prompt"
            components.queryItems = [URLQueryItem(name: "client", value: "kytweet")]
            return components.url
        }

        return URL(string: "https://example.invalid/api/tweet-prompt?client=kytweet")
    }

    private static func loadDictionary() -> [String: Any]? {
        for url in candidateSecretURLs() {
            if let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                LoggingService.logToFile(level: .debug, message: "[ShareSecrets] Loaded Secrets.plist from: \(url.path)")
                return dict
            }
        }
        LoggingService.logToFile(level: .error, message: "[ShareSecrets] Could not locate Secrets.plist")
        return nil
    }

    private static func candidateSecretURLs() -> [URL] {
        var urls: [URL] = []

        if let bundleURL = Bundle.main.url(forResource: "Secrets", withExtension: "plist") {
            urls.append(bundleURL)
        }

        let containingAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Secrets.plist")
        urls.append(containingAppURL)

        if let appGroupURL = SharedInbox.containerURL()?.appendingPathComponent("Secrets.plist") {
            urls.append(appGroupURL)
        }

        return urls
    }
}

struct ShareHTTPError: Error, LocalizedError {
    let statusCode: Int
    let service: String
    let body: String?

    var errorDescription: String? {
        "\(service) request failed (\(statusCode))."
    }
}

extension ShareHTTPError {
    var debugDescription: String {
        var message = "\(service) HTTP \(statusCode)"
        if let body, !body.isEmpty {
            message += " body=\(body.prefix(180))"
        }
        return message
    }
}

private struct ShareSSEEvent {
    let name: String?
    let data: String
}

private enum ShareSSEStream {
    static func events(for request: URLRequest, session: URLSession = .shared) -> AsyncThrowingStream<ShareSSEEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var currentEventName: String?
                var dataLines: [String] = []
                var buffer = Data()

                func flush() {
                    guard !dataLines.isEmpty else { return }
                    continuation.yield(
                        ShareSSEEvent(
                            name: currentEventName,
                            data: dataLines.joined(separator: "\n")
                        )
                    )
                    currentEventName = nil
                    dataLines.removeAll(keepingCapacity: true)
                }

                func consume(_ line: String) {
                    if line.hasPrefix("event:") {
                        currentEventName = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if line.hasPrefix("data:") {
                        let dataLine = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                        dataLines.append(String(dataLine))
                    } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flush()
                    }
                }

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var bodyData = Data()
                        for try await byte in bytes {
                            if bodyData.count < 8_000 {
                                bodyData.append(byte)
                            } else {
                                break
                            }
                        }
                        throw ShareHTTPError(
                            statusCode: http.statusCode,
                            service: request.url?.host ?? "network",
                            body: bodyData.isEmpty ? nil : String(decoding: bodyData, as: UTF8.self)
                        )
                    }

                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A {
                            let lineData = buffer.dropLast()
                            buffer.removeAll(keepingCapacity: true)
                            let line = String(decoding: lineData, as: UTF8.self)
                            consume(line)
                        }
                    }

                    if !buffer.isEmpty {
                        consume(String(decoding: buffer, as: UTF8.self))
                    }

                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

struct ShareClaudePreparedRequest {
    let request: URLRequest
    let bodyData: Data
}

private struct ShareGroqTranscriptionResponse: Decodable {
    let text: String
}

private enum ShareMultipartFormData {
    static func body(
        fields: [String: String],
        fileFieldName: String,
        fileURL: URL,
        mimeType: String,
        boundary: String
    ) throws -> Data {
        var data = Data()
        let separator = "--\(boundary)\r\n"

        for (key, value) in fields {
            data.append(Data(separator.utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            data.append(Data(value.utf8))
            data.append(Data("\r\n".utf8))
        }

        let fileData = try Data(contentsOf: fileURL)
        data.append(Data(separator.utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
        data.append(Data("--\(boundary)--\r\n".utf8))

        return data
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "flac":
            return "audio/flac"
        case "mp3", "mpga":
            return "audio/mpeg"
        case "mp4":
            return "video/mp4"
        case "mpeg":
            return "video/mpeg"
        case "m4a":
            return "audio/mp4"
        case "ogg":
            return "audio/ogg"
        case "wav":
            return "audio/wav"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }
}

struct ShareClaudeClient {
    let apiKey: String
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let streamingRequestTimeout: TimeInterval = 60 * 60 * 24
    private static let streamingSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = streamingRequestTimeout
        configuration.timeoutIntervalForResource = streamingRequestTimeout
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    func makePreparedRequest(
        systemPrompt: String,
        userInput: String,
        model: ShareTweetModel,
        stream: Bool,
        userAgent: String
    ) throws -> ShareClaudePreparedRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.streamingRequestTimeout

        if model == .claudeSonnet {
            request.setValue("context-1m-2025-08-07", forHTTPHeaderField: "anthropic-beta")
        }

        let payload: [String: Any] = [
            "model": model.modelId,
            "max_tokens": model.maxTokens,
            "temperature": model.temperature,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userInput]
            ],
            "stream": stream
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = bodyData
        return ShareClaudePreparedRequest(request: request, bodyData: bodyData)
    }

    func stream(systemPrompt: String, userInput: String, model: ShareTweetModel) -> AsyncThrowingStream<String, Error> {
        let preparedRequest: ShareClaudePreparedRequest
        do {
            preparedRequest = try makePreparedRequest(
                systemPrompt: systemPrompt,
                userInput: userInput,
                model: model,
                stream: true,
                userAgent: "ExplainerShareExtension/1.0"
            )
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in ShareSSEStream.events(for: preparedRequest.request, session: Self.streamingSession) {
                        if event.data == "[DONE]" { break }
                        if let delta = parseDelta(event: event) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func extractMessageText(from data: Data) throws -> String {
        let decoded = try JSONDecoder().decode(ClaudeMessageResponse.self, from: data)
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            throw ShareTweetGenerationError.emptyModelOutput
        }
        return text
    }

    private func parseDelta(event: ShareSSEEvent) -> String? {
        guard let data = event.data.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let eventType = event.name ?? (payload["type"] as? String)
        if eventType == "content_block_delta" {
            if let delta = payload["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return text
            }
        }
        if eventType == "content_block_start" {
            if let content = payload["content_block"] as? [String: Any],
               let text = content["text"] as? String {
                return text
            }
        }
        return nil
    }
}

private struct ClaudeMessageResponse: Decodable {
    let content: [ClaudeMessageContentBlock]
}

private struct ClaudeMessageContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct ShareTweetClient {
    enum Scope {
        case singleTweet
        case replyChain
        case fullThread

        var maxTweets: String {
            switch self {
            case .singleTweet: return "1"
            case .replyChain: return "15"
            case .fullThread: return "15"
            }
        }

        var conversationModeQueryValue: String? {
            switch self {
            case .singleTweet:
                return nil
            case .replyChain:
                return "reply_chain"
            case .fullThread:
                return "full_thread"
            }
        }

        var expectsConcatenatedConversation: Bool {
            switch self {
            case .singleTweet:
                return false
            case .replyChain, .fullThread:
                return true
            }
        }
    }

    func fetchTweetText(url tweetURL: String, tweetAPIBaseURL: URL?, scope: Scope) async throws -> String {
        if let tweetAPIBaseURL {
            do {
                return try await fetchViaService(url: tweetURL, tweetAPIBaseURL: tweetAPIBaseURL, scope: scope)
            } catch {
                LoggingService.logToFile(level: .error, message: "[ShareTweetClient] Service failed: \(error)")

                if case .replyChain = scope {
                    do {
                        LoggingService.logToFile(level: .info, message: "[ShareTweetClient] Falling back to full_thread mode")
                        return try await fetchViaService(url: tweetURL, tweetAPIBaseURL: tweetAPIBaseURL, scope: .fullThread)
                    } catch {
                        LoggingService.logToFile(level: .error, message: "[ShareTweetClient] full_thread fallback failed: \(error)")
                    }
                }
            }
        }
        return try await fetchViaOEmbed(url: tweetURL)
    }

    private func fetchViaService(url tweetURL: String, tweetAPIBaseURL: URL, scope: Scope) async throws -> String {
        let endpoint: URL
        let loweredPath = tweetAPIBaseURL.path.lowercased()
        if loweredPath.hasSuffix("/scrape_thread") || loweredPath.hasSuffix("/scrape_thread/") {
            endpoint = tweetAPIBaseURL
        } else {
            endpoint = tweetAPIBaseURL.appendingPathComponent("scrape_thread", isDirectory: true)
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "tweet_url", value: tweetURL))
        queryItems.append(URLQueryItem(name: "max_tweets", value: scope.maxTweets))
        if let conversationMode = scope.conversationModeQueryValue {
            queryItems.append(URLQueryItem(name: "conversation_mode", value: conversationMode))
        }
        queryItems.append(URLQueryItem(name: "download_images", value: "false"))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ShareHTTPError(statusCode: http.statusCode, service: "TweetService", body: String(data: data, encoding: .utf8))
        }

        let decoded = try JSONDecoder().decode(ScrapeThreadResponse.self, from: data)
        guard decoded.status?.lowercased() != "error" else {
            throw ShareHTTPError(statusCode: 502, service: "TweetService", body: decoded.message)
        }

        guard let selected = pickTweet(from: decoded.tweets, scope: scope) else {
            throw ShareTweetGenerationError.emptySourceTweet
        }

        let text = normalizeTweetText(selected.text, scope: scope)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ShareTweetGenerationError.emptySourceTweet
        }
        return trimmed
    }

    private func fetchViaOEmbed(url tweetURL: String) async throws -> String {
        guard var components = URLComponents(string: "https://publish.twitter.com/oembed") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: tweetURL),
            URLQueryItem(name: "omit_script", value: "1"),
            URLQueryItem(name: "dnt", value: "1"),
        ]

        guard let requestURL = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ShareHTTPError(statusCode: http.statusCode, service: "Twitter oEmbed", body: String(data: data, encoding: .utf8))
        }

        let decoded = try JSONDecoder().decode(OEmbedResponse.self, from: data)
        let text = extractTweetTextFromHTML(decoded.html).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw ShareTweetGenerationError.emptySourceTweet
        }
        return text
    }

    private func pickTweet(from tweets: [ScrapedTweet], scope: Scope) -> ScrapedTweet? {
        if tweets.isEmpty { return nil }

        if scope.expectsConcatenatedConversation,
           let conversation = tweets.first(where: { ($0.authorHandle ?? "").lowercased() == "conversacion_completa" }) {
            let text = conversation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("\n\n---\n\n") {
                return conversation
            }
        }

        return tweets.first(where: { tweet in
            let handle = (tweet.authorHandle ?? "").lowercased()
            return handle != "conversacion_completa" && !tweet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? tweets.first
    }

    private func normalizeTweetText(_ text: String, scope: Scope) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.expectsConcatenatedConversation else { return trimmed }
        if trimmed.contains("\n\n---\n\n"), let first = trimmed.components(separatedBy: "\n\n---\n\n").first {
            return first.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func extractTweetTextFromHTML(_ html: String) -> String {
        if let paragraph = firstRegexCapture(in: html, pattern: "<p[^>]*>([\\s\\S]*?)</p>") {
            return htmlToPlainText(paragraph)
        }
        let plain = htmlToPlainText(html)
        if let dash = plain.range(of: "—") {
            return String(plain[..<dash.lowerBound])
        }
        return plain
    }

    private func htmlToPlainText(_ html: String) -> String {
        let wrapped = "<div>\(html)</div>"
        if let data = wrapped.data(using: .utf8) {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                return attributed.string
            }
        }
        return html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }
}

private struct OEmbedResponse: Decodable {
    let html: String
}

private struct ScrapeThreadResponse: Decodable {
    let status: String?
    let message: String?
    let tweets: [ScrapedTweet]
}

private struct ScrapedTweet: Decodable {
    let text: String
    let authorHandle: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case authorHandle = "author_handle"
    }
}

struct GeneratedTweetDraft {
    let es: String
    let en: String
}

enum TweetDraftParser {
    static func extractTweetDrafts(raw: String, expectedCount: Int) -> [GeneratedTweetDraft] {
        let blocks = XMLExtractor.extractAllTagContents(from: raw, tag: "tweet")
        let draftsFromBlocks = blocks.compactMap { block -> GeneratedTweetDraft? in
            let es = extractTweetField(raw: block, tag: "content_es")
            let en = extractTweetField(raw: block, tag: "content_en")
            let resolvedEN = en.isEmpty ? es : en
            guard !es.isEmpty || !resolvedEN.isEmpty else { return nil }
            return GeneratedTweetDraft(es: es, en: resolvedEN)
        }

        let rawDrafts = draftsFromBlocks.isEmpty
            ? {
                let es = extractTweetField(raw: raw, tag: "content_es")
                let en = extractTweetField(raw: raw, tag: "content_en")
                let resolvedEN = en.isEmpty ? es : en
                guard !es.isEmpty || !resolvedEN.isEmpty else { return [] }
                return [GeneratedTweetDraft(es: es, en: resolvedEN)]
            }()
            : draftsFromBlocks

        var seen = Set<String>()
        let uniqueDrafts = rawDrafts.filter { draft in
            let key = "\(draft.es.trimmingCharacters(in: .whitespacesAndNewlines))\u{241F}\(draft.en.trimmingCharacters(in: .whitespacesAndNewlines))"
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        return Array(uniqueDrafts.prefix(max(1, expectedCount)))
    }

    private static func extractTweetField(raw: String, tag: String) -> String {
        XMLExtractor.decodeEntities(
            XMLExtractor.stripCdata(
                XMLExtractor.extractTagLenient(from: raw, tag: tag)
            )
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ShareTweetGenerationService {
    private let client = ShareTweetClient()
    private let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    func fetchSourceTweet(tweetURL: String, includeThread: Bool) async throws -> String {
        let secrets = try ShareSecrets.load()
        let scope: ShareTweetClient.Scope = includeThread ? .replyChain : .singleTweet
        let apiURL = secrets.tweetApiURL.flatMap(URL.init(string:))

        let text = try await withTimeout(seconds: 30) {
            try await client.fetchTweetText(url: tweetURL, tweetAPIBaseURL: apiURL, scope: scope)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ShareTweetGenerationError.emptySourceTweet
        }
        return trimmed
    }

    func generateTweets(
        sourceTweetText: String,
        sourceTweetURL: String,
        mode: String,
        intention: String?,
        feedback: String?,
        previousDraft: String?,
        notes: String?,
        model: ShareTweetModel,
        variationSeed: String,
        draftCount: Int
    ) async throws -> [GeneratedTweetDraft] {
        let safeDraftCount = max(1, min(draftCount, 4))
        let secrets = try ShareSecrets.load()
        let systemPrompt = await PromptLibrary.standaloneTweetGeneratorSystemPrompt(remoteURL: secrets.promptApiURL)
        let userInput = PromptLibrary.buildStandaloneTweetGeneratorInput(
            sourceTweetText: sourceTweetText,
            sourceTweetURL: sourceTweetURL,
            mode: mode,
            intention: intention,
            feedback: feedback,
            previousDraft: previousDraft,
            notes: notes,
            variationSeed: variationSeed,
            draftCount: safeDraftCount
        )

        let stream = ShareClaudeClient(apiKey: secrets.anthropicApiKey)
            .stream(systemPrompt: systemPrompt, userInput: userInput, model: model)

        let startedAt = Date()
        LoggingService.logToFile(
            level: .info,
            message: "[ShareTweetGen] start model=\(model.modelId) draftCount=\(safeDraftCount) sourceChars=\(sourceTweetText.count) intentionChars=\((intention ?? "").count) previousDraftChars=\((previousDraft ?? "").count) feedbackChars=\((feedback ?? "").count)"
        )

        var raw = ""
        var firstChunkLogged = false
        for try await chunk in stream {
            try Task.checkCancellation()
            raw += chunk
            if !firstChunkLogged {
                firstChunkLogged = true
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                LoggingService.logToFile(level: .info, message: "[ShareTweetGen] first_chunk elapsedMs=\(elapsedMs)")
            }
        }

        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        LoggingService.logToFile(level: .info, message: "[ShareTweetGen] complete elapsedMs=\(totalMs) rawChars=\(raw.count)")

        let drafts = TweetDraftParser.extractTweetDrafts(raw: raw, expectedCount: safeDraftCount)
        if drafts.isEmpty {
            LoggingService.logToFile(level: .error, message: "[ShareTweetGen] Empty output raw=\(raw.prefix(280))")
            throw ShareTweetGenerationError.emptyModelOutput
        }

        LoggingService.logToFile(level: .info, message: "[ShareTweetGen] parsed drafts=\(drafts.count)")
        return drafts
    }

    func transcribeAudio(fileURL: URL) async throws -> String {
        let secrets = try ShareSecrets.load()
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try ShareMultipartFormData.body(
            fields: [
                "model": "whisper-large-v3-turbo",
                "response_format": "json",
                "temperature": "0"
            ],
            fileFieldName: "file",
            fileURL: fileURL,
            mimeType: ShareMultipartFormData.mimeType(for: fileURL),
            boundary: boundary
        )

        let request: URLRequest = {
            var request = URLRequest(url: groqEndpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(secrets.groqApiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
            return request
        }()

        LoggingService.logToFile(level: .info, message: "[ShareTweetGen] transcribe start file=\(fileURL.lastPathComponent)")

        let data = try await withTimeout(seconds: 120) {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ShareHTTPError(
                    statusCode: http.statusCode,
                    service: "groq",
                    body: String(data: data.prefix(4_000), encoding: .utf8)
                )
            }
            return data
        }

        let decoded = try JSONDecoder().decode(ShareGroqTranscriptionResponse.self, from: data)
        let transcript = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw ShareTweetGenerationError.emptyTranscription
        }

        LoggingService.logToFile(level: .info, message: "[ShareTweetGen] transcribe complete chars=\(transcript.count)")
        return transcript
    }

    /// Format a tweet with line breaks using Sonnet 4.5 (hardcoded model).
    func formatLineBreaks(
        tweetText: String,
        language: String,
        lineBreakMode: String
    ) async throws -> String {
        let secrets = try ShareSecrets.load()
        let systemPrompt = PromptLibrary.lineBreakFormatterSystemPrompt()
        let userInput = PromptLibrary.buildLineBreakFormatterInput(
            tweetText: tweetText,
            language: language,
            lineBreakMode: lineBreakMode
        )

        // Always use Sonnet 4.5 for line break formatting — fast and precise
        let model = ShareTweetModel.claudeSonnet

        LoggingService.logToFile(level: .info, message: "[LineBreakFormatter] Formatting tweet, lang=\(language) mode=\(lineBreakMode) model=\(model.modelId)")

        let stream = ShareClaudeClient(apiKey: secrets.anthropicApiKey)
            .stream(systemPrompt: systemPrompt, userInput: userInput, model: model)

        let raw = try await withTimeout(seconds: 30) {
            var response = ""
            for try await chunk in stream {
                try Task.checkCancellation()
                response += chunk
            }
            return response
        }

        let formatted = XMLExtractor.decodeEntities(
            XMLExtractor.stripCdata(
                XMLExtractor.extractTagLenient(from: raw, tag: "formatted_text")
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if formatted.isEmpty {
            LoggingService.logToFile(level: .error, message: "[LineBreakFormatter] Empty output raw=\(raw.prefix(280))")
            throw ShareTweetGenerationError.emptyModelOutput
        }

        LoggingService.logToFile(level: .info, message: "[LineBreakFormatter] Success, formatted length=\(formatted.count)")
        return formatted
    }
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ShareTweetGenerationError.timedOut
            }
            guard let first = try await group.next() else {
                throw ShareTweetGenerationError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}
