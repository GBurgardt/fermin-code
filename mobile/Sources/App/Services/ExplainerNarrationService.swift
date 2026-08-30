import AVFoundation
import CryptoKit
import Foundation

struct ExplainerNarrationSection: Codable, Hashable, Sendable {
    let title: String
    let paragraphs: [String]
}

struct ExplainerNarrationWord: Codable, Hashable, Identifiable, Sendable {
    let index: Int
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: Int { index }
}

struct ExplainerNarrationAsset: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let audioFilePath: String
    let scriptText: String
    let sections: [ExplainerNarrationSection]
    let words: [ExplainerNarrationWord]
    let duration: TimeInterval
    let provider: String
    let model: String
    let voiceId: String
    let fromCache: Bool

    var audioURL: URL {
        URL(fileURLWithPath: audioFilePath)
    }
}

struct ExplainerNarrationService {
    private static let cacheVersion = "explainer-narration-v2-sonnet-whatsapp"
    private static let cacheMaxAge: TimeInterval = 30 * 24 * 60 * 60
    private static let cartesiaSampleRate: UInt32 = 44_100
    private static let cartesiaChannels: UInt16 = 1
    private static let cartesiaBitsPerSample: UInt16 = 16

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func narrationAsset(for explanation: String, title: String?) async throws -> ExplainerNarrationAsset {
        let cleanSource = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSource.isEmpty else {
            throw ExplainerNarrationError.emptyExplanation
        }

        let cacheKey = Self.cacheKey(for: cleanSource)
        try cleanupOldCacheEntries()

        if let cached = try loadCachedAsset(cacheKey: cacheKey) {
            return cached
        }

        let generatedScript = try await generateNarrativeScript(explanation: cleanSource, title: title)
        let optimizedScript = try await optimizeScriptForTTS(generatedScript, sourceMarkdown: cleanSource)
        let synthesis = try await synthesizeCartesiaSSE(text: optimizedScript.scriptText)
        let audioURL = try writeAudioCache(cacheKey: cacheKey, pcmData: synthesis.pcmAudioData)
        let words = normalizedWords(synthesis.words, fallbackText: optimizedScript.scriptText, duration: synthesis.duration)

        let duration = max(
            synthesis.duration,
            words.last?.endTime ?? 0,
            Self.estimatedDuration(for: optimizedScript.scriptText)
        )
        let asset = ExplainerNarrationAsset(
            id: cacheKey,
            title: optimizedScript.title.isEmpty ? (title ?? "Explicación") : optimizedScript.title,
            audioFilePath: audioURL.path,
            scriptText: optimizedScript.scriptText,
            sections: optimizedScript.sections,
            words: words,
            duration: duration,
            provider: "cartesia",
            model: synthesis.model,
            voiceId: synthesis.voiceId,
            fromCache: false
        )

        try writeMetadata(asset, sourceHash: cacheKey)
        return asset
    }

    func generateNarrativeScript(explanation: String, title: String?) async throws -> ParsedNarrationScript {
        let prompt = Self.scriptGenerationPrompt
        let textBlocks = [
            "TITULO SUGERIDO:\n\(title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Explicación de KyCode")",
            "EXPLICACION MARKDOWN ORIGINAL:\n\(explanation)"
        ]

        let xml = try await runAnthropicMessagesPrompt(
            model: Self.anthropicNarrationModel,
            systemPrompt: prompt,
            textBlocks: textBlocks,
            maxTokens: 3_200,
            temperature: 0.42,
            requestLabel: "kycode-explainer-script"
        )
        return try parseNarrationXML(xml.text, fallbackTitle: title ?? "Explicación")
    }

    func optimizeScriptForTTS(_ script: ParsedNarrationScript, sourceMarkdown: String) async throws -> ParsedNarrationScript {
        let xml = script.rawXML.isEmpty ? script.asXML() : script.rawXML
        let response = try await runAnthropicMessagesPrompt(
            model: Self.anthropicNarrationModel,
            systemPrompt: Self.ttsOptimizationPrompt,
            textBlocks: [
                "GUION XML LIMPIO:\n\(xml)",
                "MARKDOWN ORIGINAL SOLO PARA REFERENCIA, NO LO COPIES LITERAL SI SUENA MAL EN VOZ:\n\(sourceMarkdown)"
            ],
            maxTokens: 3_200,
            temperature: 0.32,
            requestLabel: "kycode-explainer-tts-optimization"
        )
        return try parseNarrationXML(response.text, fallbackTitle: script.title)
    }

    private static var anthropicNarrationModel: String {
        ExplainerNarrationSecrets.optionalString("KYCODE_NARRATION_ANTHROPIC_MODEL")
            ?? ExplainerNarrationSecrets.optionalString("ANTHROPIC_MODEL")
            ?? "claude-sonnet-4-6"
    }

    private func runAnthropicMessagesPrompt(
        model: String,
        systemPrompt: String,
        textBlocks: [String],
        maxTokens: Int,
        temperature: Double,
        requestLabel: String
    ) async throws -> AnthropicPromptResult {
        guard let apiKey = ExplainerNarrationSecrets.anthropicApiKey() else {
            throw ExplainerNarrationError.missingAnthropicKey
        }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ExplainerNarrationError.invalidEndpoint("Anthropic")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("kycode-mobile-narration/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": textBlocks.joined(separator: "\n\n")]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens
        ], options: [])

        let startedAt = Date()
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExplainerNarrationError.badResponse("Anthropic")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(2_000), encoding: .utf8) ?? ""
            throw ExplainerNarrationError.httpStatus("Anthropic", http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        let content = decoded.extractedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ExplainerNarrationError.emptyModelResponse(requestLabel)
        }

        NSLog(
            "%@",
            "[narration:anthropic] \(requestLabel) ok model=\(decoded.model ?? model) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
        return AnthropicPromptResult(model: decoded.model ?? model, text: Self.stripXMLFences(content))
    }

    private func synthesizeCartesiaSSE(text: String) async throws -> CartesiaSynthesisResult {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw ExplainerNarrationError.emptyScript
        }
        guard let apiKey = ExplainerNarrationSecrets.optionalString("CARTESIA_API_KEY") else {
            throw ExplainerNarrationError.missingCartesiaKey
        }
        guard let url = URL(string: "https://api.cartesia.ai/tts/sse") else {
            throw ExplainerNarrationError.invalidEndpoint("Cartesia")
        }

        let model = ExplainerNarrationSecrets.optionalString("CARTESIA_TTS_MODEL") ?? "sonic-3.5"
        let voiceId = ExplainerNarrationSecrets.optionalString("CARTESIA_TTS_VOICE_ID_ES")
            ?? ExplainerNarrationSecrets.optionalString("CARTESIA_TTS_VOICE_ID")
            ?? "2695b6b5-5543-4be1-96d9-3967fb5e7fec"
        let apiVersion = ExplainerNarrationSecrets.optionalString("CARTESIA_VERSION")
            ?? ExplainerNarrationSecrets.optionalString("CARTESIA_TTS_VERSION")
            ?? "2026-03-01"

        let requestBody: [String: Any] = [
            "model_id": model,
            "transcript": transcript,
            "voice": [
                "mode": "id",
                "id": voiceId
            ],
            "output_format": [
                "container": "raw",
                "encoding": "pcm_s16le",
                "sample_rate": Self.cartesiaSampleRate
            ],
            "language": "es",
            "context_id": UUID().uuidString,
            "add_timestamps": true,
            "add_phoneme_timestamps": false,
            "use_normalized_timestamps": true,
            "generation_config": [
                "emotion": "excited"
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue(apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("kycode-mobile-narration/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExplainerNarrationError.badResponse("Cartesia")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(2_000), encoding: .utf8) ?? ""
            throw ExplainerNarrationError.httpStatus("Cartesia", http.statusCode, body)
        }

        let parsed = try parseCartesiaSSE(data)
        let durationFromBytes = Double(parsed.audio.count) / Double(Self.cartesiaSampleRate * UInt32(Self.cartesiaChannels) * UInt32(Self.cartesiaBitsPerSample / 8))
        return CartesiaSynthesisResult(
            pcmAudioData: parsed.audio,
            words: parsed.words,
            duration: max(durationFromBytes, parsed.words.last?.endTime ?? 0),
            model: model,
            voiceId: voiceId
        )
    }

    private func parseCartesiaSSE(_ data: Data) throws -> (audio: Data, words: [ExplainerNarrationWord]) {
        guard let stream = String(data: data, encoding: .utf8) else {
            throw ExplainerNarrationError.badResponse("Cartesia SSE")
        }
        let normalized = stream.replacingOccurrences(of: "\r\n", with: "\n")
        let eventBlocks = normalized.components(separatedBy: "\n\n")
        var audio = Data()
        var words: [ExplainerNarrationWord] = []

        for block in eventBlocks {
            let payload = block
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { line in
                    String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, let payloadData = payload.data(using: .utf8) else {
                continue
            }

            let event = try JSONDecoder().decode(CartesiaSSEEvent.self, from: payloadData)
            switch event.type {
            case "chunk":
                if let dataString = event.data, let chunk = Data(base64Encoded: dataString) {
                    audio.append(chunk)
                }
            case "timestamps":
                if let timestampWords = event.wordTimestamps {
                    let count = min(
                        timestampWords.words.count,
                        timestampWords.start.count,
                        timestampWords.end.count
                    )
                    for offset in 0..<count {
                        let text = timestampWords.words[offset].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        words.append(
                            ExplainerNarrationWord(
                                index: words.count,
                                text: text,
                                startTime: timestampWords.start[offset],
                                endTime: max(timestampWords.end[offset], timestampWords.start[offset] + 0.04)
                            )
                        )
                    }
                }
            case "error":
                throw ExplainerNarrationError.httpStatus(
                    "Cartesia",
                    event.statusCode ?? 500,
                    event.message ?? event.title ?? "Cartesia SSE error"
                )
            default:
                continue
            }
        }

        guard !audio.isEmpty else {
            throw ExplainerNarrationError.emptyAudio
        }
        return (audio, words)
    }

    private func parseNarrationXML(_ source: String, fallbackTitle: String) throws -> ParsedNarrationScript {
        let cleanSource = Self.stripXMLFences(source)
        let explicitRoot = XMLExtractor.extractTagLenient(from: cleanSource, tag: "explainer_narration")
        let root = explicitRoot.isEmpty ? XMLExtractor.extractTagLenient(from: cleanSource, tag: "narration") : explicitRoot
        let xml = root.isEmpty ? cleanSource : root
        let title = cleanXMLText(XMLExtractor.extractTagLenient(from: xml, tag: "title"))
        let chapterSource = XMLExtractor.extractTagLenient(from: xml, tag: "chapters")
        let chapterXMLs = XMLExtractor.extractAllTagContents(
            from: chapterSource.isEmpty ? xml : chapterSource,
            tag: "chapter"
        )
        let chapterSections = chapterXMLs.enumerated().compactMap { index, chapterXML -> ExplainerNarrationSection? in
            let chapterTitle = cleanXMLText(XMLExtractor.extractTagLenient(from: chapterXML, tag: "title"))
            let chapterText = cleanXMLText(XMLExtractor.extractTagLenient(from: chapterXML, tag: "text"))
            let paragraphTags = XMLExtractor.extractAllTagContents(from: chapterXML, tag: "paragraph")
                .map(cleanXMLText)
                .filter { !$0.isEmpty }
            let paragraphs = paragraphTags.isEmpty ? Self.paragraphs(from: chapterText) : paragraphTags
            guard !chapterTitle.isEmpty || !paragraphs.isEmpty else { return nil }
            return ExplainerNarrationSection(
                title: chapterTitle.isEmpty ? "Audio \(index + 1)" : chapterTitle,
                paragraphs: paragraphs
            )
        }

        let sectionSource = XMLExtractor.extractTagLenient(from: xml, tag: "sections")
        let sectionXMLs = XMLExtractor.extractAllTagContents(
            from: sectionSource.isEmpty ? xml : sectionSource,
            tag: "section"
        )
        let legacySections = sectionXMLs.compactMap { sectionXML -> ExplainerNarrationSection? in
            let sectionTitle = cleanXMLText(XMLExtractor.extractTagLenient(from: sectionXML, tag: "title"))
            let paragraphs = XMLExtractor.extractAllTagContents(from: sectionXML, tag: "paragraph")
                .map(cleanXMLText)
                .filter { !$0.isEmpty }
            guard !sectionTitle.isEmpty || !paragraphs.isEmpty else { return nil }
            return ExplainerNarrationSection(
                title: sectionTitle.isEmpty ? "Sección" : sectionTitle,
                paragraphs: paragraphs
            )
        }
        let sections = chapterSections.isEmpty ? legacySections : chapterSections
        let explicitPlainText = cleanXMLText(XMLExtractor.extractTagLenient(from: xml, tag: "plain_text"))
        let plainText = explicitPlainText.isEmpty ? Self.plainText(from: sections) : explicitPlainText
        guard !plainText.isEmpty else {
            throw ExplainerNarrationError.emptyScript
        }
        return ParsedNarrationScript(
            title: title.isEmpty ? fallbackTitle : title,
            sections: sections,
            scriptText: plainText,
            rawXML: cleanSource
        )
    }

    private func cleanXMLText(_ source: String) -> String {
        XMLExtractor.decodeEntities(XMLExtractor.stripCdata(source))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedWords(
        _ words: [ExplainerNarrationWord],
        fallbackText: String,
        duration: TimeInterval
    ) -> [ExplainerNarrationWord] {
        if !words.isEmpty {
            return words.enumerated().map { offset, word in
                ExplainerNarrationWord(
                    index: offset,
                    text: word.text,
                    startTime: max(0, word.startTime),
                    endTime: max(word.endTime, word.startTime + 0.04)
                )
            }
        }
        return Self.estimatedWords(for: fallbackText, duration: duration)
    }

    private func cacheDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents
            .appendingPathComponent("KyCode", isDirectory: true)
            .appendingPathComponent("AudioCache", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audioURL(cacheKey: String) throws -> URL {
        try cacheDirectory().appendingPathComponent("\(cacheKey).wav")
    }

    private func metadataURL(cacheKey: String) throws -> URL {
        try cacheDirectory().appendingPathComponent("\(cacheKey).json")
    }

    private func loadCachedAsset(cacheKey: String) throws -> ExplainerNarrationAsset? {
        let metadataURL = try metadataURL(cacheKey: cacheKey)
        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder.narration.decode(ExplainerNarrationCacheMetadata.self, from: data),
              FileManager.default.fileExists(atPath: metadata.asset.audioFilePath) else {
            return nil
        }

        metadata.lastAccessedAt = Date()
        if let encoded = try? JSONEncoder().encode(metadata) {
            try? encoded.write(to: metadataURL, options: .atomic)
        }

        let cached = metadata.asset
        return ExplainerNarrationAsset(
            id: cached.id,
            title: cached.title,
            audioFilePath: cached.audioFilePath,
            scriptText: cached.scriptText,
            sections: cached.sections,
            words: cached.words,
            duration: cached.duration,
            provider: cached.provider,
            model: cached.model,
            voiceId: cached.voiceId,
            fromCache: true
        )
    }

    private func writeAudioCache(cacheKey: String, pcmData: Data) throws -> URL {
        let wav = Self.wavData(
            pcmData: pcmData,
            sampleRate: Self.cartesiaSampleRate,
            channels: Self.cartesiaChannels,
            bitsPerSample: Self.cartesiaBitsPerSample
        )
        let url = try audioURL(cacheKey: cacheKey)
        try wav.write(to: url, options: .atomic)
        return url
    }

    private func writeMetadata(_ asset: ExplainerNarrationAsset, sourceHash: String) throws {
        let metadata = ExplainerNarrationCacheMetadata(
            cacheVersion: Self.cacheVersion,
            sourceHash: sourceHash,
            asset: asset,
            createdAt: Date(),
            lastAccessedAt: Date()
        )
        let encoded = try JSONEncoder.prettyNarration.encode(metadata)
        try encoded.write(to: metadataURL(cacheKey: sourceHash), options: .atomic)
    }

    private func cleanupOldCacheEntries() throws {
        let directory = try cacheDirectory()
        let cutoff = Date().addingTimeInterval(-Self.cacheMaxAge)
        let metadataFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        for metadataURL in metadataFiles {
            let data = try? Data(contentsOf: metadataURL)
            let metadata = data.flatMap { try? JSONDecoder.narration.decode(ExplainerNarrationCacheMetadata.self, from: $0) }
            let lastAccessed = metadata?.lastAccessedAt ?? (
                try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            ) ?? Date()
            guard lastAccessed < cutoff else { continue }
            if let audioPath = metadata?.asset.audioFilePath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            try? FileManager.default.removeItem(at: metadataURL)
        }
    }
}

struct ParsedNarrationScript: Hashable, Sendable {
    let title: String
    let sections: [ExplainerNarrationSection]
    let scriptText: String
    let rawXML: String

    func asXML() -> String {
        let sectionsXML = sections.map { section in
            let paragraphs = section.paragraphs.map { "<paragraph><![CDATA[\($0)]]></paragraph>" }.joined(separator: "\n")
            return """
            <section>
              <title><![CDATA[\(section.title)]]></title>
              \(paragraphs)
            </section>
            """
        }.joined(separator: "\n")
        return """
        <explainer_narration>
          <title><![CDATA[\(title)]]></title>
          <sections>
        \(sectionsXML)
          </sections>
          <plain_text><![CDATA[\(scriptText)]]></plain_text>
        </explainer_narration>
        """
    }
}

private struct AnthropicPromptResult: Sendable {
    let model: String
    let text: String
}

private struct CartesiaSynthesisResult: Sendable {
    let pcmAudioData: Data
    let words: [ExplainerNarrationWord]
    let duration: TimeInterval
    let model: String
    let voiceId: String
}

private struct ExplainerNarrationCacheMetadata: Codable {
    let cacheVersion: String
    let sourceHash: String
    let asset: ExplainerNarrationAsset
    let createdAt: Date
    var lastAccessedAt: Date
}

private struct AnthropicMessageResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    let model: String?
    let content: [ContentBlock]?

    var extractedContent: String {
        (content ?? [])
            .filter { $0.type == "text" || $0.type == nil }
            .map { $0.text ?? "" }
            .joined(separator: "\n")
    }
}

private struct CartesiaSSEEvent: Decodable {
    let type: String?
    let done: Bool?
    let statusCode: Int?
    let data: String?
    let title: String?
    let message: String?
    let error: String?
    let wordTimestamps: CartesiaWordTimestamps?

    enum CodingKeys: String, CodingKey {
        case type
        case done
        case statusCode = "status_code"
        case data
        case title
        case message
        case error
        case wordTimestamps = "word_timestamps"
    }
}

private struct CartesiaWordTimestamps: Decodable {
    let words: [String]
    let start: [Double]
    let end: [Double]
}

private enum ExplainerNarrationError: LocalizedError {
    case emptyExplanation
    case emptyScript
    case missingAnthropicKey
    case missingCartesiaKey
    case invalidEndpoint(String)
    case badResponse(String)
    case httpStatus(String, Int, String)
    case emptyModelResponse(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .emptyExplanation:
            return "No hay una explicación para narrar todavía."
        case .emptyScript:
            return "No se pudo convertir la explicación en un guión narrable."
        case .missingAnthropicKey:
            return "Falta ANTHROPIC_API_KEY para generar el guión con Claude Sonnet."
        case .missingCartesiaKey:
            return "Falta CARTESIA_API_KEY para generar la voz."
        case .invalidEndpoint(let service):
            return "El endpoint de \(service) no es válido."
        case .badResponse(let service):
            return "\(service) devolvió una respuesta inválida."
        case .httpStatus(let service, let status, let body):
            let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanBody.isEmpty {
                return "\(service) rechazó la solicitud (HTTP \(status))."
            }
            return "\(service) rechazó la solicitud (HTTP \(status)): \(cleanBody.prefix(220))"
        case .emptyModelResponse(let label):
            return "Claude no devolvió texto útil para \(label)."
        case .emptyAudio:
            return "Cartesia no devolvió audio."
        }
    }
}

private enum ExplainerNarrationSecrets {
    static func anthropicApiKey() -> String? {
        optionalString("ANTHROPIC_API_KEY")
    }

    static func optionalString(_ key: String) -> String? {
        for url in candidateSecretURLs() {
            guard let dict = NSDictionary(contentsOf: url) as? [String: Any],
                  let raw = dict[key] as? String else {
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("YOUR_") {
                return trimmed
            }
        }
        let envValue = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty, !envValue.hasPrefix("YOUR_") {
            return envValue
        }
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

private extension ExplainerNarrationService {
    static var scriptGenerationPrompt: String {
        """
        Sos un programador senior mandándole audios de WhatsApp a su jefe para explicarle qué acabás de implementar.

        La situación exacta:
        - Tu jefe está caminando o haciendo otra cosa y quiere entender rápido qué pasó.
        - No le mandás un documento formal ni un podcast. Le mandás 2 o 3 audios cortos, claros, humanos.
        - Cada audio tiene una idea central. Primero lo ubicás. Después explicás cómo lo resolviste. Si aporta, cerrás con estado actual, riesgos o qué sigue.
        - El tono es de colega confiable: directo, relajado, preciso. No impostado. No teatral. No "locutor".
        - Podés usar marcadores naturales: "básicamente", "o sea", "digamos", "la idea es". Usalos con moderación, como una persona real que ordena ideas.

        Convertí la explicación Markdown técnica en ese guión conversacional.

        Reglas no negociables:
        - Devolvé SOLO XML válido. Sin markdown, sin fences, sin explicación externa.
        - Usá exactamente esta raíz: <explainer_narration>.
        - Usá 2 o 3 capítulos. Pensalos como 2 o 3 audios de WhatsApp, no como secciones de informe.
        - Cada capítulo debe tener un título corto y útil, visible antes de escuchar: "Qué hice", "Cómo lo resolví", "Estado y próximos pasos", o variantes específicas.
        - Conservá la estructura conceptual de la explicación. Si aparecen "Cambios principales", "Qué se hizo", "Estado actual" o "Qué falta", integralo en los capítulos sin perderlo.
        - Limpiá Markdown que se lee mal: remové #, *, backticks, tablas, URLs largas, syntax fences y marcas visuales.
        - El código debe resumirse en lenguaje oral. No leas bloques de código enteros salvo nombres cortos de archivos, comandos o símbolos imprescindibles.
        - Mantené el contenido fiel. No inventes estado, archivos, resultados ni promesas.
        - Escribí en español rioplatense neutro. Conversacional, pero prolijo.
        - Frases cortas. Párrafos de 1 a 3 oraciones. Saltos de línea generosos.
        - Si una idea es importante, podés reformularla una vez de forma más simple, como haría alguien que quiere asegurarse de que se entendió.
        - No cierres con entusiasmo vacío. Cerrá con estado concreto.

        Formato obligatorio:
        <explainer_narration>
          <title><![CDATA[Título breve de la explicación]]></title>
          <chapters>
            <chapter number="1">
              <title><![CDATA[Qué hice]]></title>
              <text><![CDATA[Primer audio. Corto, humano, claro.

        Con saltos de línea entre ideas.]]></text>
            </chapter>
            <chapter number="2">
              <title><![CDATA[Cómo lo resolví]]></title>
              <text><![CDATA[Segundo audio. Decisiones técnicas en lenguaje simple.]]></text>
            </chapter>
          </chapters>
          <plain_text><![CDATA[Qué hice

        Primer audio. Corto, humano, claro.

        Con saltos de línea entre ideas.

        Cómo lo resolví

        Segundo audio. Decisiones técnicas en lenguaje simple.]]></plain_text>
        </explainer_narration>
        """
    }

    static var ttsOptimizationPrompt: String {
        """
        Sos director de voz para una app móvil. Recibís un guión XML ya limpio y lo optimizás para Cartesia Sonic 3.5, manteniendo el mismo contrato XML con capítulos.

        Objetivo: que suene como 2 o 3 audios de WhatsApp de un programador que explica bien su trabajo a su jefe. Natural, cálido y preciso, sin volverse teatral ni robótico.

        Reglas:
        - Devolvé SOLO XML con raíz <explainer_narration>.
        - No agregues hechos nuevos. No elimines información importante.
        - Preservá 2 o 3 capítulos. Cada capítulo debe funcionar como un audio corto con título visible.
        - Evitá signos técnicos que arruinan la voz: backticks, bullets crudos, URLs largas, barras repetidas, hashes largos.
        - Usá puntuación para ritmo: puntos, comas y saltos de párrafo. Usá puntos suspensivos solo si una pausa breve mejora la comprensión.
        - No uses tags escénicos entre corchetes. Esta narración debe sonar sobria.
        - Mantené oraciones cortas y fluidas. Si una frase es larga, dividila.
        - Dejá pausas naturales entre capítulos usando doble salto de línea en <plain_text>.
        - El texto visible debe respirar: saltos de línea generosos, párrafos chicos, títulos claros.
        - En nombres técnicos, separá con contexto oral: "el archivo KycodeRootView punto Swift", no una lectura mecánica de símbolos.

        Few-shot:

        Entrada mediocre:
        "Se cambió `npm test` y fallan 4 specs; revisar typescript/build."
        Salida buena:
        "Qué hice.

        Básicamente, ajusté el flujo de pruebas.

        Quedaron cuatro tests fallando. Están relacionados con TypeScript y con el build, así que ese es el próximo punto concreto."

        Entrada mediocre:
        "- UI: fix radius, icons, shadows. - TODO: run install-ios."
        Salida buena:
        "Qué cambié.

        Refiné la interfaz para que se sienta menos prototipo y más producto terminado.

        O sea: radios más suaves, íconos más prolijos y sombras más sutiles.

        Qué falta.

        Falta ejecutar la instalación en iPhone con el script install iOS, y mirarlo en dispositivo real."

        Entrada mediocre:
        "Estado actual: OK, build passed, but device locked."
        Salida buena:
        "Estado actual.

        El build terminó correctamente. La instalación pudo completarse, pero el iPhone estaba bloqueado y no permitió abrir la app automáticamente."
        """
    }

    static func stripXMLFences(_ source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(from sections: [ExplainerNarrationSection]) -> String {
        sections.map { section in
            ([section.title] + section.paragraphs)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func paragraphs(from text: String) -> [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func cacheKey(for source: String) -> String {
        let input = "\(cacheVersion)\n\(source)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func estimatedDuration(for text: String) -> TimeInterval {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return max(1.8, Double(words) * 0.42)
    }

    static func estimatedWords(for text: String, duration: TimeInterval) -> [ExplainerNarrationWord] {
        let tokens = text
            .replacingOccurrences(of: "\n", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)
        guard !tokens.isEmpty else { return [] }
        let totalDuration = max(duration, estimatedDuration(for: text))
        let step = totalDuration / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            ExplainerNarrationWord(
                index: index,
                text: token,
                startTime: Double(index) * step,
                endTime: min(totalDuration, Double(index + 1) * step)
            )
        }
    }

    static func wavData(pcmData: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        var data = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = UInt32(36 + pcmData.count)

        data.append(Data("RIFF".utf8))
        data.appendLittleEndian(chunkSize)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.append(Data("data".utf8))
        data.appendLittleEndian(UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [
            UInt8(value & 0x00ff),
            UInt8((value & 0xff00) >> 8)
        ])
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0x000000ff),
            UInt8((value & 0x0000ff00) >> 8),
            UInt8((value & 0x00ff0000) >> 16),
            UInt8((value & 0xff000000) >> 24)
        ])
    }
}

private extension JSONEncoder {
    static var prettyNarration: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var narration: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
