import Foundation

enum PromptLibrary {
    private static let tweetPromptCacheKey = "TweetPromptCache.KyTweet.Default"

    static func standaloneTweetGeneratorSystemPrompt(remoteURL: URL?) async -> String {
        if let remoteURL,
           let remotePrompt = await fetchRemotePrompt(from: remoteURL, cacheKey: tweetPromptCacheKey) {
            return augmentStandaloneTweetPrompt(remotePrompt)
        }

        if let cachedPrompt = cachedPrompt(for: tweetPromptCacheKey), !cachedPrompt.isEmpty {
            return augmentStandaloneTweetPrompt(cachedPrompt)
        }

        if let text = loadPrompt(named: "tweet-generator-standalone") {
            return augmentStandaloneTweetPrompt(text)
        }
        return augmentStandaloneTweetPrompt(fallbackStandaloneTweetGeneratorPrompt)
    }

    static func buildStandaloneTweetGeneratorInput(
        sourceTweetText: String,
        sourceTweetURL: String,
        mode: String,
        intention: String?,
        feedback: String?,
        previousDraft: String?,
        notes: String?,
        variationSeed: String,
        draftCount: Int
    ) -> String {
        let trimmedTweet = sourceTweetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = sourceTweetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIntention = (intention ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFeedback = (feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPreviousDraft = (previousDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSeed = variationSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDraftCount = max(1, min(draftCount, 4))

        var payload = "<tweet_reply_request>\n"
        payload += "  <source_tweet_url><![CDATA[\n\(trimmedURL)\n  ]]></source_tweet_url>\n"
        payload += "  <source_tweet_text><![CDATA[\n\(trimmedTweet)\n  ]]></source_tweet_text>\n"
        payload += "  <tweet_type><![CDATA[\n\(trimmedMode)\n  ]]></tweet_type>\n"
        payload += "  <intention><![CDATA[\n\(trimmedIntention)\n  ]]></intention>\n"
        payload += "  <previous_draft><![CDATA[\n\(trimmedPreviousDraft)\n  ]]></previous_draft>\n"
        payload += "  <iteration_feedback><![CDATA[\n\(trimmedFeedback)\n  ]]></iteration_feedback>\n"
        payload += "  <variation_seed><![CDATA[\n\(trimmedSeed)\n  ]]></variation_seed>\n"
        payload += "  <draft_count><![CDATA[\n\(safeDraftCount)\n  ]]></draft_count>\n"
        payload += "  <notes><![CDATA[\n\(trimmedNotes)\n  ]]></notes>\n"
        payload += "</tweet_reply_request>\n\n"
        payload += "REMINDER:\n"
        payload += "- Return ONLY a <tweet_generator> XML block. No markdown. No extra text.\n"
        payload += "- <internal_monologue> must be the FIRST tag inside <tweet_generator>.\n"
        payload += "- <internal_monologue> must contain BETWEEN 200 AND 300 LINES, one concrete idea per line.\n"
        payload += "- Do NOT write final tweet copy inside <internal_monologue>.\n"
        payload += "- Generate EXACTLY \(safeDraftCount) tweet alternative(s).\n"
        payload += "- Keep each tweet <= 280 characters.\n"
        payload += "- After <internal_monologue>, return a single <tweets> block with one <tweet> per option.\n"
        payload += "- Each <tweet> must contain ONLY <content_es> and <content_en> wrapped in CDATA.\n"
        payload += "- Make every alternative materially different from the others: different angle, framing, implication, or punchline. No cosmetic rewrites.\n"
        payload += "- Never include ]]> in the output.\n"
        payload += "- CRITICAL: For <content_es>, ALL Spanish tildes/accents are MANDATORY. Never omit accents.\n"
        return payload
    }

    // MARK: - Line Break Formatter

    static func lineBreakFormatterSystemPrompt() -> String {
        if let text = loadPrompt(named: "tweet-linebreak-formatter") {
            return text
        }
        return fallbackLineBreakFormatterPrompt
    }

    static func buildLineBreakFormatterInput(
        tweetText: String,
        language: String,
        lineBreakMode: String
    ) -> String {
        var payload = "<tweet_linebreak_request>\n"
        payload += "  <language>\(language)</language>\n"
        payload += "  <line_break_mode>\(lineBreakMode)</line_break_mode>\n"
        payload += "  <tweet_text><![CDATA[\(tweetText)]]></tweet_text>\n"
        payload += "</tweet_linebreak_request>"
        return payload
    }

    private static func loadPrompt(named name: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: "prompt.txt"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        let containingAppBundleURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let promptURL = containingAppBundleURL
            .appendingPathComponent("Prompts", isDirectory: true)
            .appendingPathComponent("\(name).prompt.txt")

        if let data = try? Data(contentsOf: promptURL),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return nil
    }

    private static func promptDefaults() -> UserDefaults? {
        UserDefaults(suiteName: SharedInbox.appGroupId)
    }

    private static func cachedPrompt(for key: String) -> String? {
        let value = promptDefaults()?.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func storePrompt(_ prompt: String, for key: String) {
        promptDefaults()?.set(prompt, forKey: key)
    }

    private static func augmentStandaloneTweetPrompt(_ prompt: String) -> String {
        prompt + """


MULTI-DRAFT EXTENSION (OBLIGATORIA SI EXISTE <draft_count> EN EL INPUT):
- Devuelve SIEMPRE un <tweet_generator> con <internal_monologue> como primer tag y <tweets> despues.
- <internal_monologue> debe tener ENTRE 200 Y 300 lineas, una idea concreta por linea.
- NO escribas tweets finales dentro de <internal_monologue>.
- Genera exactamente la cantidad indicada en <draft_count>.
- Si <draft_count> es mayor a 1, devuelve un unico bloque XML con este formato:
<tweet_generator>
  <internal_monologue>
    (200-300 lineas)
  </internal_monologue>
  <tweets>
    <tweet>
      <content_es><![CDATA[...]]></content_es>
      <content_en><![CDATA[...]]></content_en>
    </tweet>
    (exactamente <draft_count> tweets)
  </tweets>
</tweet_generator>
- Cada alternativa debe ser materialmente distinta de las demas: cambia el angulo, el framing, el valor aportado o el remate. No hagas variaciones cosmeticas.
- Mantene exactamente la misma voz y todas las reglas del prompt base en cada alternativa.
"""
    }

    private static func fetchRemotePrompt(from url: URL, cacheKey: String) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 4

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                LoggingService.logToFile(level: .error, message: "[PromptLibrary] Tweet prompt HTTP error url=\(url.absoluteString)")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.logToFile(level: .error, message: "[PromptLibrary] Tweet prompt invalid JSON url=\(url.absoluteString)")
                return nil
            }

            let prompt = (json["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else {
                LoggingService.logToFile(level: .error, message: "[PromptLibrary] Tweet prompt missing text url=\(url.absoluteString)")
                return nil
            }

            storePrompt(prompt, for: cacheKey)
            LoggingService.logToFile(level: .info, message: "[PromptLibrary] Tweet prompt loaded from API url=\(url.absoluteString)")
            return prompt
        } catch {
            LoggingService.logToFile(level: .error, message: "[PromptLibrary] Tweet prompt fetch failed: \(error)")
            return nil
        }
    }

    private static let fallbackStandaloneTweetGeneratorPrompt = """
TWEET REPLY GENERATOR (STANDALONE)

You receive a source tweet and must generate the number of response drafts requested in <draft_count>, each in ES + EN in the user's style.
Modes:
- reply: direct response to the source tweet.
- quote: tweet that references the source tweet.

OUTPUT (MANDATORY)
Return ONLY:
<tweet_generator>
  <internal_monologue>
    (200-300 lines)
  </internal_monologue>
  <tweets>
    <tweet>
      <content_es><![CDATA[(tweet <= 280 chars)]]></content_es>
      <content_en><![CDATA[(tweet <= 280 chars)]]></content_en>
    </tweet>
    (exactly <draft_count> tweets)
  </tweets>
</tweet_generator>

RULES
- <internal_monologue> must be the FIRST tag inside <tweet_generator>.
- <internal_monologue> must contain BETWEEN 200 AND 300 LINES, one concrete idea per line.
- Do NOT write final tweet copy inside <internal_monologue>.
- Generate exactly the number of drafts requested in <draft_count>.
- Respect the user's intention when provided.
- source_tweet_text may be a reply chain separated by "---" (oldest -> newest).
- If it's a chain, the LAST segment is the tweet you must reply to; earlier segments are context only.
- If previous_draft + iteration_feedback are present, improve that draft instead of starting from zero.
- Each alternative must be materially different from the others: different angle, framing, implication, or punchline.
- No hashtags, no emojis, no marketing language.
- ES and EN must be natural adaptations (not literal translation).
- For content_es: ALL Spanish accents/tildes are MANDATORY (información, está, más, también, etc).
"""

    private static let fallbackLineBreakFormatterPrompt = """
TWEET LINE BREAK FORMATTER

Your ONLY task: reorganize a tweet by inserting line breaks to improve readability.

INPUT: XML with <tweet_linebreak_request> containing language, line_break_mode (single|double), and tweet_text.
OUTPUT: XML with <tweet_linebreak_response> containing <formatted_text> in CDATA.

RULES:
- Return ONLY the XML block.
- Do NOT change any word, accent, punctuation, URL, mention, or hashtag.
- Only insert or move line breaks.
- single mode: one line break between blocks.
- double mode: blank line (double line break) between blocks, but do NOT automatically split every sentence into its own block.
- Each block should contain one complete idea or phrase.
- Do not split every sentence by default. If two short sentences belong to the same impulse or argument, keep them together.
- Avoid a pattern that feels too perfect or mechanical. The rhythm should feel human, organic, and slightly irregular.
- Mix very short blocks with slightly longer ones when it helps. Not every block should have the same size.
- Aim for short visual paragraphs, usually 1 or 2 lines in a tweet. Avoid dense blocks, but also avoid artificial staccato formatting.
- Do not break a sentence just to make it look prettier. Breaks should follow real meaning, tone, or punchline.
"""
}
