import Foundation

enum VoiceTranscriptionJobPhase: String, Codable, Sendable {
    case preparing
    case transcribing
    case sending
    case failed

    var messageStatus: String {
        "voice_\(rawValue)"
    }

    var isActive: Bool {
        self != .failed
    }
}

struct VoiceTranscriptionRouteIdentity: Codable, Equatable, Sendable {
    let selectedProfileId: String
    let routedProfileId: String
    let presentedWindowId: String
    let remoteWindowId: String
    let baseURL: String
    let sessionId: String
}

struct VoiceTranscriptionOwner: Equatable, Sendable {
    let connectionGeneration: UInt64
    let route: VoiceTranscriptionRouteIdentity
    let requiresDurableContract: Bool
}

enum VoiceTranscriptionOwnershipPolicy {
    static func owns(
        expected: VoiceTranscriptionOwner?,
        current: VoiceTranscriptionOwner?
    ) -> Bool {
        guard let expected, let current else { return false }
        return expected == current
    }

    static func routeMatches(
        expected: VoiceTranscriptionRouteIdentity?,
        current: VoiceTranscriptionRouteIdentity?
    ) -> Bool {
        guard let expected, let current else { return false }
        return expected == current
    }
}

struct VoiceTranscriptionJob: Identifiable, Equatable, Sendable {
    let id: String
    let messageId: String
    let windowId: String
    let duration: TimeInterval
    let createdAt: Date
    var updatedAt: Date
    var phase: VoiceTranscriptionJobPhase
    var transcriptText: String
    var filePath: String?
    var errorMessage: String?
    var owner: VoiceTranscriptionOwner?
    var voiceDraftId: String?
    var attemptId: UUID

    static func pending(
        windowId: String,
        duration: TimeInterval,
        now: Date = Date(),
        id: String = UUID().uuidString,
        owner: VoiceTranscriptionOwner? = nil
    ) -> VoiceTranscriptionJob {
        VoiceTranscriptionJob(
            id: id,
            messageId: "voice-\(id)",
            windowId: windowId,
            duration: duration,
            createdAt: now,
            updatedAt: now,
            phase: .preparing,
            transcriptText: "",
            filePath: nil,
            errorMessage: nil,
            owner: owner,
            voiceDraftId: nil,
            attemptId: UUID()
        )
    }

    func applying(delta: String, now: Date = Date()) -> VoiceTranscriptionJob {
        var next = self
        next.phase = .transcribing
        next.updatedAt = now
        next.transcriptText += delta
        next.errorMessage = nil
        return next
    }

    func replacingTranscript(with text: String, now: Date = Date()) -> VoiceTranscriptionJob {
        var next = self
        next.phase = .sending
        next.updatedAt = now
        next.transcriptText = text
        next.errorMessage = nil
        return next
    }

    func failing(with message: String, now: Date = Date()) -> VoiceTranscriptionJob {
        var next = self
        next.phase = .failed
        next.updatedAt = now
        next.errorMessage = message
        return next
    }
}

enum VoiceTranscriptionPolicy {
    static let confirmationDeadline: TimeInterval = 0.5
    static let transcriptionTimeout: Duration = .seconds(30)
    static let realtimeTargetDelayMilliseconds = 240
    static let realtimeChunkBytes = 32 * 1_024

    static func statusTitle(for status: String?) -> String? {
        switch status {
        case VoiceTranscriptionJobPhase.preparing.messageStatus:
            return "Enviado · preparando audio"
        case VoiceTranscriptionJobPhase.transcribing.messageStatus:
            return "Transcribiendo…"
        case VoiceTranscriptionJobPhase.sending.messageStatus:
            return "Transcripción lista · enviando"
        case VoiceTranscriptionJobPhase.failed.messageStatus:
            return "Transcripción fallida"
        default:
            return nil
        }
    }
}

enum VoiceTranscriptionError: LocalizedError {
    case invalidRealtimeEndpoint
    case invalidWaveFile
    case unsupportedWaveFormat
    case invalidServerEvent
    case server(String)
    case emptyTranscript
    case timedOut
    case ownerChanged

    var errorDescription: String? {
        switch self {
        case .invalidRealtimeEndpoint:
            return "El endpoint realtime de Mistral no es válido."
        case .invalidWaveFile:
            return "El audio grabado no es un WAV válido."
        case .unsupportedWaveFormat:
            return "El audio no está en PCM mono de 16 kHz."
        case .invalidServerEvent:
            return "Mistral devolvió un evento realtime inválido."
        case .server(let message):
            return message.isEmpty ? "Mistral rechazó la transcripción realtime." : message
        case .emptyTranscript:
            return "Mistral devolvió una transcripción vacía."
        case .timedOut:
            return "La transcripción tardó más de 30 segundos."
        case .ownerChanged:
            return "La sesión cambió. Volvé a la Mac original para revisar o reintentar el audio."
        }
    }
}

enum VoiceTranscriptionTimeout {
    static func run<T: Sendable>(
        for duration: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw VoiceTranscriptionError.timedOut
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }
}

struct PCM16WavePayload: Equatable, Sendable {
    let sampleRate: Int
    let channels: Int
    let bytes: Data

    static func read(from data: Data) throws -> PCM16WavePayload {
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw VoiceTranscriptionError.invalidWaveFile
        }

        var offset = 12
        var format: (audioFormat: UInt16, channels: UInt16, sampleRate: UInt32, bits: UInt16)?
        var audioBytes: Data?

        while offset + 8 <= data.count {
            let chunkName = String(data: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(readUInt32LE(data, offset: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else {
                throw VoiceTranscriptionError.invalidWaveFile
            }

            if chunkName == "fmt ", chunkSize >= 16 {
                format = (
                    readUInt16LE(data, offset: payloadStart),
                    readUInt16LE(data, offset: payloadStart + 2),
                    readUInt32LE(data, offset: payloadStart + 4),
                    readUInt16LE(data, offset: payloadStart + 14)
                )
            } else if chunkName == "data" {
                audioBytes = Data(data[payloadStart..<payloadEnd])
            }

            offset = payloadEnd + (chunkSize.isMultiple(of: 2) ? 0 : 1)
        }

        guard let format, let audioBytes, !audioBytes.isEmpty else {
            throw VoiceTranscriptionError.invalidWaveFile
        }
        guard format.audioFormat == 1,
              format.channels == 1,
              format.sampleRate == 16_000,
              format.bits == 16 else {
            throw VoiceTranscriptionError.unsupportedWaveFormat
        }
        return PCM16WavePayload(
            sampleRate: Int(format.sampleRate),
            channels: Int(format.channels),
            bytes: audioBytes
        )
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

struct MistralRealtimeTranscriptionClient: Sendable {
    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let targetDelayMilliseconds: Int
    private let urlSession: URLSession

    init(
        apiKey: String,
        endpoint: String,
        model: String,
        targetDelayMilliseconds: Int = VoiceTranscriptionPolicy.realtimeTargetDelayMilliseconds,
        urlSession: URLSession = .shared
    ) throws {
        guard let endpointURL = URL(string: endpoint) else {
            throw VoiceTranscriptionError.invalidRealtimeEndpoint
        }
        self.apiKey = apiKey
        self.endpoint = endpointURL
        self.model = model
        self.targetDelayMilliseconds = targetDelayMilliseconds
        self.urlSession = urlSession
    }

    func transcribe(
        waveFileURL: URL,
        onDelta: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let wave = try await Task.detached(priority: .userInitiated) {
            try PCM16WavePayload.read(from: Data(contentsOf: waveFileURL))
        }.value

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "model" }
        queryItems.append(URLQueryItem(name: "model", value: model))
        components?.queryItems = queryItems
        guard let websocketURL = components?.url else {
            throw VoiceTranscriptionError.invalidRealtimeEndpoint
        }

        var request = URLRequest(url: websocketURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("kycode-mobile-voxtral-realtime/1.0", forHTTPHeaderField: "User-Agent")

        let socket = urlSession.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
        }

        try await waitForSession(socket)
        try await sendJSON(
            [
                "type": "session.update",
                "session": [
                    "audio_format": [
                        "encoding": "pcm_s16le",
                        "sample_rate": wave.sampleRate,
                    ],
                    "target_streaming_delay_ms": targetDelayMilliseconds,
                ],
            ],
            to: socket
        )

        for start in stride(
            from: 0,
            to: wave.bytes.count,
            by: VoiceTranscriptionPolicy.realtimeChunkBytes
        ) {
            try Task.checkCancellation()
            let end = min(wave.bytes.count, start + VoiceTranscriptionPolicy.realtimeChunkBytes)
            let encoded = Data(wave.bytes[start..<end]).base64EncodedString()
            try await sendJSON(
                [
                    "type": "input_audio.append",
                    "audio": encoded,
                ],
                to: socket
            )
            await Task.yield()
        }
        try await sendJSON(["type": "input_audio.flush"], to: socket)
        try await sendJSON(["type": "input_audio.end"], to: socket)

        var accumulated = ""
        while true {
            try Task.checkCancellation()
            let event = try await receiveJSON(from: socket)
            switch event["type"] as? String {
            case "transcription.text.delta":
                guard let delta = event["text"] as? String, !delta.isEmpty else { continue }
                accumulated += delta
                await onDelta(delta)
            case "transcription.done":
                let finalText = ((event["text"] as? String) ?? accumulated)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !finalText.isEmpty else {
                    throw VoiceTranscriptionError.emptyTranscript
                }
                return finalText
            case "error":
                throw VoiceTranscriptionError.server(Self.errorMessage(from: event))
            default:
                continue
            }
        }
    }

    private func waitForSession(_ socket: URLSessionWebSocketTask) async throws {
        while true {
            let event = try await receiveJSON(from: socket)
            switch event["type"] as? String {
            case "session.created":
                return
            case "error":
                throw VoiceTranscriptionError.server(Self.errorMessage(from: event))
            default:
                continue
            }
        }
    }

    private func sendJSON(_ object: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceTranscriptionError.invalidServerEvent
        }
        try await socket.send(.string(text))
    }

    private func receiveJSON(from socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            throw VoiceTranscriptionError.invalidServerEvent
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceTranscriptionError.invalidServerEvent
        }
        return object
    }

    private static func errorMessage(from event: [String: Any]) -> String {
        guard let error = event["error"] as? [String: Any] else { return "" }
        if let message = error["message"] as? String {
            return message
        }
        if let message = error["message"] as? [String: Any],
           let detail = message["detail"] as? String {
            return detail
        }
        return ""
    }
}
