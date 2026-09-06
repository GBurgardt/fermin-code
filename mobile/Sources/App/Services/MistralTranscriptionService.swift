import Foundation

struct MistralTranscriptionService: Sendable {
    private let apiKey: String
    private let endpoint: URL
    private let modelName: String
    private let language: String
    private let timeout: TimeInterval
    private let realtimeEndpoint: String
    private let realtimeModelName: String
    private let preferRealtime: Bool

    init(
        apiKey: String,
        endpoint: String = "https://api.mistral.ai/v1/audio/transcriptions",
        modelName: String = "voxtral-mini-latest",
        language: String = "es",
        timeout: TimeInterval = 300,
        realtimeEndpoint: String = "wss://api.mistral.ai/v1/audio/transcriptions/realtime",
        realtimeModelName: String = "voxtral-mini-transcribe-realtime-2602",
        preferRealtime: Bool = false
    ) throws {
        guard let endpointURL = URL(string: endpoint) else {
            throw MistralTranscriptionError.invalidEndpoint
        }
        self.apiKey = apiKey
        self.endpoint = endpointURL
        self.modelName = modelName
        self.language = language
        self.timeout = timeout
        self.realtimeEndpoint = realtimeEndpoint
        self.realtimeModelName = realtimeModelName
        self.preferRealtime = preferRealtime
    }

    static func configured() throws -> MistralTranscriptionService {
        try MistralTranscriptionService(
            apiKey: MistralTranscriptionSecrets.loadApiKey(),
            endpoint: MistralTranscriptionSecrets.loadOptionalString("WT_VOXTRAL_ENDPOINT")
                ?? "https://api.mistral.ai/v1/audio/transcriptions",
            modelName: MistralTranscriptionSecrets.loadOptionalString("WT_VOXTRAL_MODEL")
                ?? "voxtral-mini-latest",
            language: MistralTranscriptionSecrets.loadOptionalString("WT_VOXTRAL_LANGUAGE") ?? "es",
            realtimeEndpoint: MistralTranscriptionSecrets.loadOptionalString("WT_VOXTRAL_REALTIME_ENDPOINT")
                ?? "wss://api.mistral.ai/v1/audio/transcriptions/realtime",
            realtimeModelName: MistralTranscriptionSecrets.loadOptionalString("WT_VOXTRAL_REALTIME_MODEL")
                ?? "voxtral-mini-transcribe-realtime-2602",
            preferRealtime: MistralTranscriptionModePolicy.parseBoolean(
                MistralTranscriptionSecrets.loadOptionalString("WT_VOXTRAL_PREFER_REALTIME")
            )
        )
    }

    func transcribeAudioFileStreaming(
        filePath: String,
        onDelta: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MistralTranscriptionError.missingAudioFile
        }

        guard MistralTranscriptionModePolicy.shouldUseRealtime(
            preferRealtime: preferRealtime,
            fileExtension: fileURL.pathExtension
        ) else {
            let transcript = try await transcribeAudioFile(filePath: filePath)
            await onDelta(transcript)
            return transcript
        }

        do {
            let realtime = try MistralRealtimeTranscriptionClient(
                apiKey: apiKey,
                endpoint: realtimeEndpoint,
                model: realtimeModelName
            )
            return try await realtime.transcribe(
                waveFileURL: fileURL,
                onDelta: onDelta
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Realtime is opt-in for genuinely live capture. The high-accuracy
            // Voxtral batch endpoint remains the correctness fallback.
            let transcript = try await transcribeAudioFile(filePath: filePath)
            await onDelta(transcript)
            return transcript
        }
    }

    func transcribeAudioFile(filePath: String) async throws -> String {
        try await transcribeAudioFileDetailed(
            filePath: filePath,
            diarize: false
        ).fullText
    }

    /// Uses Voxtral's documented diarization option while preserving the
    /// original String-returning API above for every existing caller.
    func transcribeAudioFileDetailed(
        filePath: String,
        diarize: Bool
    ) async throws -> VoiceTranscriptionResult {
        let startedAt = Date()
        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MistralTranscriptionError.missingAudioFile
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try AudioMultipartFormData.body(
            fields: MistralTranscriptionRequestPolicy.fields(
                model: modelName,
                language: language,
                diarize: diarize
            ),
            fileFieldName: "file",
            fileURL: fileURL,
            mimeType: AudioMultipartFormData.mimeType(for: fileURL),
            boundary: boundary
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("kycode-mobile-voxtral/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw MistralTranscriptionError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(4_000), encoding: .utf8) ?? ""
            throw MistralTranscriptionError.httpStatus(http.statusCode, bodyPreview)
        }

        let latencyMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let result = try MistralTranscriptionResponseDecoder.decode(
            data: data,
            modelFallback: modelName,
            latencyMilliseconds: latencyMilliseconds
        )
        NSLog(
            "[KyCode][Voxtral] batch transcription completed model=%@ latency_ms=%d diarized_segments=%d",
            modelName,
            latencyMilliseconds,
            result.segments.count
        )
        return result
    }
}

enum MistralTranscriptionModePolicy {
    static func shouldUseRealtime(
        preferRealtime: Bool,
        fileExtension: String
    ) -> Bool {
        preferRealtime && fileExtension.lowercased() == "wav"
    }

    static func parseBoolean(_ rawValue: String?) -> Bool {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(normalized)
    }
}

enum MistralTranscriptionRequestPolicy {
    static func fields(
        model: String,
        language: String,
        diarize: Bool
    ) -> [String: String] {
        var fields = [
            "model": model,
            "language": language,
            "temperature": "0"
        ]
        if diarize {
            fields["diarize"] = "true"
            fields["timestamp_granularities"] = "segment"
        }
        return fields
    }
}

enum MistralTranscriptionResponseDecoder {
    static func decode(
        data: Data,
        modelFallback: String,
        latencyMilliseconds: Int
    ) throws -> VoiceTranscriptionResult {
        let decoded = try JSONDecoder().decode(MistralTranscriptionEnvelope.self, from: data)
        let transcript = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw MistralTranscriptionError.emptyTranscript
        }

        let segments: [VoiceTranscriptionSegment] = (decoded.segments ?? []).enumerated().compactMap { index, segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.end > segment.start,
                  !text.isEmpty else {
                return nil
            }
            let startMilliseconds = Int((segment.start * 1_000).rounded())
            return VoiceTranscriptionSegment(
                id: "voxtral-\(index)-\(startMilliseconds)",
                speakerId: segment.speakerId,
                start: segment.start,
                end: segment.end,
                text: text
            )
        }

        return VoiceTranscriptionResult(
            fullText: transcript,
            segments: segments,
            provider: .mistralVoxtral,
            model: decoded.model ?? modelFallback,
            latencyMilliseconds: latencyMilliseconds
        )
    }
}

private struct MistralTranscriptionEnvelope: Decodable {
    let text: String
    let model: String?
    let segments: [MistralTranscriptionSegmentEnvelope]?
}

private struct MistralTranscriptionSegmentEnvelope: Decodable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speakerId: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case speakerId = "speaker_id"
    }
}

private enum MistralTranscriptionError: LocalizedError {
    case missingSecrets
    case missingMistralKey
    case invalidEndpoint
    case missingAudioFile
    case badResponse
    case httpStatus(Int, String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingSecrets:
            return "Secrets.plist no está disponible."
        case .missingMistralKey:
            return "MISTRAL_API_KEY no está configurada."
        case .invalidEndpoint:
            return "El endpoint de Mistral no es válido."
        case .missingAudioFile:
            return "No encontré el audio guardado."
        case .badResponse:
            return "Mistral devolvió una respuesta inválida."
        case .httpStatus(let status, let bodyPreview):
            let preview = bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if preview.isEmpty {
                return "Mistral rechazó la transcripción (HTTP \(status))."
            }
            return "Mistral rechazó la transcripción (HTTP \(status)): \(preview.prefix(180))"
        case .emptyTranscript:
            return "Mistral devolvió una transcripción vacía."
        }
    }
}

private enum MistralTranscriptionSecrets {
    static func loadApiKey() throws -> String {
        if let value = loadOptionalString("MISTRAL_API_KEY") {
            return value
        }
        throw candidateSecretURLs().isEmpty ? MistralTranscriptionError.missingSecrets : MistralTranscriptionError.missingMistralKey
    }

    static func loadOptionalString(_ key: String) -> String? {
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
        if let envValue, !envValue.isEmpty {
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
