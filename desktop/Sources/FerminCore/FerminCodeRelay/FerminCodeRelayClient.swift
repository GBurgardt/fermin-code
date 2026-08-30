import Foundation

public enum FerminRelayHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

public struct FerminRelayHTTPConfiguration: Equatable, Sendable {
    public static let maximumAttachmentBytes = 20 * 1_048_576
    public static let maximumAttachmentUploadBodyBytes = maximumAttachmentBytes + 128 * 1_024

    public var requestTimeout: TimeInterval
    public var commandTimeout: TimeInterval
    public var maximumJSONRequestBodyBytes: Int
    public var maximumUploadRequestBodyBytes: Int
    public var maximumResponseBodyBytes: Int
    public var maximumErrorMessageBytes: Int
    public var maximumSSEFrameBytes: Int
    public var maximumBufferedSSEDeliveries: Int

    public init(
        requestTimeout: TimeInterval = 20,
        commandTimeout: TimeInterval = 150,
        maximumJSONRequestBodyBytes: Int = 1_048_576,
        maximumUploadRequestBodyBytes: Int = Self.maximumAttachmentUploadBodyBytes,
        maximumResponseBodyBytes: Int = 32 * 1_048_576,
        maximumErrorMessageBytes: Int = 65_536,
        maximumSSEFrameBytes: Int = 5 * 1_048_576,
        maximumBufferedSSEDeliveries: Int = 16
    ) {
        self.requestTimeout = max(1, requestTimeout)
        self.commandTimeout = max(1, commandTimeout)
        self.maximumJSONRequestBodyBytes = max(1, maximumJSONRequestBodyBytes)
        self.maximumUploadRequestBodyBytes = max(1, maximumUploadRequestBodyBytes)
        self.maximumResponseBodyBytes = max(1, maximumResponseBodyBytes)
        self.maximumErrorMessageBytes = max(1, maximumErrorMessageBytes)
        self.maximumSSEFrameBytes = max(1, maximumSSEFrameBytes)
        self.maximumBufferedSSEDeliveries = max(1, maximumBufferedSSEDeliveries)
    }
}

public enum FerminRelayHTTPError: Error, Equatable, Sendable {
    case invalidToken
    case aggregateProfileHasNoEndpoint
    case requestBodyTooLarge(actualBytes: Int, maximumBytes: Int)
    case responseBodyTooLarge(maximumBytes: Int)
    case invalidResponse
    case httpStatus(statusCode: Int, serverCode: String?, message: String)
    case decoding(typeName: String)
    case transport(code: Int)
    case streamTransportUnavailable
    case streamBufferOverflow(stage: FerminRelayStreamBufferStage)
}

extension FerminRelayHTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidToken: return "El token del relay no es válido."
        case .aggregateProfileHasNoEndpoint: return "Todo combina dos relays y no tiene un endpoint propio."
        case let .requestBodyTooLarge(_, maximumBytes):
            return "La solicitud supera el límite de \(maximumBytes) bytes."
        case let .responseBodyTooLarge(maximumBytes):
            return "La respuesta supera el límite de \(maximumBytes) bytes."
        case .invalidResponse: return "El relay devolvió una respuesta inválida."
        case let .httpStatus(_, _, message): return message
        case .decoding: return "El relay devolvió datos incompatibles."
        case .transport: return "No se pudo conectar con el relay."
        case .streamTransportUnavailable: return "El transporte no admite eventos en vivo."
        case .streamBufferOverflow:
            return "El consumidor del stream quedó atrás; hay que revalidar el estado."
        }
    }

    public var requiresFullRefetch: Bool {
        if case .streamBufferOverflow = self { return true }
        return false
    }
}

public enum FerminRelayStreamBufferStage: String, Equatable, Sendable {
    case bytes
    case deliveries
}

public struct FerminRelayTransportResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, item in
            result[item.key.lowercased()] = item.value
        }
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct FerminRelaySSEConnection: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let chunks: AsyncThrowingStream<Data, Error>

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
    }
}

public protocol FerminRelayHTTPTransport: Sendable {
    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> FerminRelayTransportResponse
}

public protocol FerminRelaySSETransport: Sendable {
    func openEventStream(for request: URLRequest) async throws -> FerminRelaySSEConnection
}

public final class FerminRelayURLSessionTransport: FerminRelayHTTPTransport,
    FerminRelaySSETransport, @unchecked Sendable {
    private let session: URLSession
    private let maximumBufferedSSEChunks: Int

    public init(session: URLSession, maximumBufferedSSEChunks: Int = 32) {
        self.session = session
        self.maximumBufferedSSEChunks = max(1, maximumBufferedSSEChunks)
    }

    public convenience init(
        requestTimeout: TimeInterval = 20,
        resourceTimeout: TimeInterval = 300
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = max(1, requestTimeout)
        configuration.timeoutIntervalForResource = max(1, resourceTimeout)
        configuration.waitsForConnectivity = true
        self.init(session: URLSession(
            configuration: configuration,
            delegate: FerminRelayNoRedirectDelegate(),
            delegateQueue: nil
        ))
    }

    public func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> FerminRelayTransportResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FerminRelayHTTPError.invalidResponse
        }
        var body = Data()
        body.reserveCapacity(min(maximumBodyBytes, 65_536))
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else {
                throw FerminRelayHTTPError.responseBodyTooLarge(
                    maximumBytes: maximumBodyBytes
                )
            }
            body.append(byte)
        }
        return FerminRelayTransportResponse(
            statusCode: response.statusCode,
            headers: Self.headers(from: response),
            body: body
        )
    }

    public func openEventStream(for request: URLRequest) async throws -> FerminRelaySSEConnection {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FerminRelayHTTPError.invalidResponse
        }
        let chunks = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .bufferingOldest(maximumBufferedSSEChunks)
        ) { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(8_192)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= 8_192 {
                            guard Self.yieldChunk(buffer, to: continuation) else { return }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty,
                       !Self.yieldChunk(buffer, to: continuation) {
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return FerminRelaySSEConnection(
            statusCode: response.statusCode,
            headers: Self.headers(from: response),
            chunks: chunks
        )
    }

    static func yieldChunk(
        _ chunk: Data,
        to continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) -> Bool {
        switch continuation.yield(chunk) {
        case .enqueued:
            return true
        case .dropped:
            continuation.finish(
                throwing: FerminRelayHTTPError.streamBufferOverflow(stage: .bytes)
            )
            return false
        case .terminated:
            return false
        @unknown default:
            continuation.finish(
                throwing: FerminRelayHTTPError.streamBufferOverflow(stage: .bytes)
            )
            return false
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, entry in
            result[String(describing: entry.key).lowercased()] = String(describing: entry.value)
        }
    }
}

public struct FerminCodeRelayClient: Sendable {
    public let source: FerminCodeRelaySource
    public let configuration: FerminRelayHTTPConfiguration
    private let token: String
    private let transport: any FerminRelayHTTPTransport
    private let streamTransport: (any FerminRelaySSETransport)?

    public init(
        source: FerminCodeRelaySource,
        token: String,
        transport: any FerminRelayHTTPTransport = FerminRelayURLSessionTransport(),
        streamTransport: (any FerminRelaySSETransport)? = nil,
        configuration: FerminRelayHTTPConfiguration = FerminRelayHTTPConfiguration()
    ) throws {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken.count >= 32,
              !normalizedToken.contains("\r"),
              !normalizedToken.contains("\n") else {
            throw FerminRelayHTTPError.invalidToken
        }
        self.source = source
        self.token = normalizedToken
        self.transport = transport
        self.streamTransport = streamTransport ?? (transport as? any FerminRelaySSETransport)
        self.configuration = configuration
    }

    public init(
        profile: FerminCodeRelayProfile,
        token: String,
        transport: any FerminRelayHTTPTransport = FerminRelayURLSessionTransport(),
        streamTransport: (any FerminRelaySSETransport)? = nil,
        configuration: FerminRelayHTTPConfiguration = FerminRelayHTTPConfiguration()
    ) throws {
        guard let source = profile.singleSource else {
            throw FerminRelayHTTPError.aggregateProfileHasNoEndpoint
        }
        try self.init(
            source: source,
            token: token,
            transport: transport,
            streamTransport: streamTransport,
            configuration: configuration
        )
    }

    public init(
        source: FerminCodeRelaySource,
        token: String,
        session: URLSession,
        configuration: FerminRelayHTTPConfiguration = FerminRelayHTTPConfiguration()
    ) throws {
        let transport = FerminRelayURLSessionTransport(session: session)
        try self.init(
            source: source,
            token: token,
            transport: transport,
            streamTransport: transport,
            configuration: configuration
        )
    }

    public func fetchHealth() async throws -> FerminRelayHealth {
        try await get(.health, as: FerminRelayHealth.self, includeAuthorization: false)
    }

    public func fetchSessions() async throws -> FerminRelaySessionsEnvelope {
        try await get(.sessions, as: FerminRelaySessionsEnvelope.self)
    }

    public func fetchSession(windowID: String) async throws -> FerminRelaySessionDetailEnvelope {
        try await get(try .session(windowID), as: FerminRelaySessionDetailEnvelope.self)
    }

    public func fetchModels(windowID: String) async throws -> FerminRelayModelCatalogEnvelope {
        let envelope = try await get(
            try .models(windowID),
            as: FerminRelayModelCatalogEnvelope.self
        )
        return FerminRelayModelCatalogEnvelope(
            ok: envelope.ok,
            data: FerminRelayRuntimePolicy.supportedModels(from: envelope.data)
        )
    }

    public func fetchProjects() async throws -> FerminRelayProjectDirectoryEnvelope {
        try await get(.projects, as: FerminRelayProjectDirectoryEnvelope.self)
    }

    public func fetchHistory(
        _ query: FerminRelaySessionHistoryQuery
    ) async throws -> FerminRelaySessionHistoryEnvelope {
        try await get(
            .sessionHistory(queryItems: query.queryItems),
            as: FerminRelaySessionHistoryEnvelope.self
        )
    }

    public func fetchRecoverableSessions(
        _ query: FerminRelaySessionRecoveryQuery
    ) async throws -> FerminRelaySessionRecoveryEnvelope {
        try await get(
            .sessionRecovery(queryItems: query.queryItems),
            as: FerminRelaySessionRecoveryEnvelope.self
        )
    }

    public func fetchPromptImproverPreference() async throws
        -> FerminRelayPromptImproverPreferenceEnvelope {
        try await get(
            .promptImproverPreference,
            as: FerminRelayPromptImproverPreferenceEnvelope.self
        )
    }

    public func setPromptImproverPreference(
        _ variant: FerminRelayPromptImproverVariant
    ) async throws -> FerminRelayPromptImproverPreferenceEnvelope {
        try await sendJSON(
            .promptImproverPreference,
            method: .put,
            body: ["variant": variant == .unknown ? "standard" : variant.rawValue],
            as: FerminRelayPromptImproverPreferenceEnvelope.self
        )
    }

    public func createSession(
        _ request: FerminRelayCreateSessionRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        if let model = request.model { try FerminRelayRuntimePolicy.validate(model: model) }
        return try await sendJSON(
            .sessions,
            method: .post,
            body: request,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func sendMessage(
        windowID: String,
        request: FerminRelaySendMessageRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .message(windowID),
            method: .post,
            body: request,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func steer(
        windowID: String,
        request: FerminRelaySteerRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .steer(windowID),
            method: .post,
            body: request,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func interrupt(
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendWithoutBody(
            try .interrupt(windowID),
            method: .post,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func rename(
        windowID: String,
        name: String,
        idempotencyKey: String? = nil
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .rename(windowID),
            method: .post,
            body: FerminRelayRenameRequest(name: name, idempotencyKey: idempotencyKey),
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func setMinimized(
        windowID: String,
        minimized: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendWithoutBody(
            try .minimized(windowID, minimized: minimized),
            method: .post,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func setPinned(
        windowID: String,
        pinned: Bool
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .pinned(windowID),
            method: .put,
            body: ["pinned": pinned],
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func archive(
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendWithoutBody(
            try .archive(windowID),
            method: .post,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func deletePermanently(
        windowID: String
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendWithoutBody(
            try .permanentDelete(windowID),
            method: .delete,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func setFeatures(
        windowID: String,
        patch: FerminRelayFeaturePatch
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .features(windowID),
            method: .post,
            body: patch,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func setRunMode(
        windowID: String,
        request: FerminRelayRunModeRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .runMode(windowID),
            method: .post,
            body: request,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func setModelSettings(
        windowID: String,
        request: FerminRelayModelSettingsRequest
    ) async throws -> FerminRelayModelSettingsEnvelope {
        try FerminRelayRuntimePolicy.validate(model: request.model)
        if let provider = request.modelProvider {
            let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "openai" || normalized == "codex" else {
                throw FerminRelayRuntimeModelError.unsupportedEngine(provider)
            }
        }
        return try await sendJSON(
            try .modelSettings(windowID),
            method: .post,
            body: request,
            as: FerminRelayModelSettingsEnvelope.self
        )
    }

    public func createSubagent(
        windowID: String,
        request: FerminRelayCreateSubagentRequest
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        if let engine = request.engine { try FerminRelayRuntimePolicy.validate(engine: engine) }
        return try await sendJSON(
            try .createSubagent(windowID),
            method: .post,
            body: request,
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func retryPromptTransform(
        windowID: String,
        messageID: String,
        idempotencyKey: String? = nil
    ) async throws -> FerminRelayDurableCommandAcknowledgement {
        try await sendJSON(
            try .retryPromptTransform(windowID: windowID, messageID: messageID),
            method: .post,
            body: FerminRelayRetryPromptRequest(
                messageID: messageID,
                idempotencyKey: idempotencyKey
            ),
            as: FerminRelayDurableCommandAcknowledgement.self
        )
    }

    public func resumeHistory(
        id: String,
        idempotencyKey: String? = nil
    ) async throws -> FerminRelayHistoryResumeEnvelope {
        try await sendJSON(
            .resumeHistory(),
            method: .post,
            body: FerminRelayResumeHistoryRequest(id: id, idempotencyKey: idempotencyKey),
            as: FerminRelayHistoryResumeEnvelope.self
        )
    }

    public func recoverSession(
        id: String,
        idempotencyKey: String? = nil
    ) async throws -> FerminRelayRecoverSessionEnvelope {
        try await sendJSON(
            .recoverSession(),
            method: .post,
            body: FerminRelayRecoverSessionRequest(id: id, idempotencyKey: idempotencyKey),
            as: FerminRelayRecoverSessionEnvelope.self
        )
    }

    public func filePreview(path: String) async throws -> FerminRelayFilePreview {
        try await sendJSON(
            .filePreview,
            method: .post,
            body: ["path": path],
            as: FerminRelayFilePreview.self
        )
    }

    public func fetchAttachmentContent(path: String) async throws -> FerminRelayAttachmentContent {
        let response = try await perform(
            endpoint: try .attachmentContent(path: path),
            method: .get,
            body: nil,
            contentType: nil,
            includeAuthorization: true,
            timeout: configuration.requestTimeout,
            maximumRequestBytes: configuration.maximumJSONRequestBodyBytes
        )
        return FerminRelayAttachmentContent(
            data: response.body,
            mimeType: response.header("content-type")?.split(separator: ";").first.map(String.init)
        )
    }

    public func uploadAttachment(
        windowID: String,
        attachment: FerminRelayAttachmentUpload
    ) async throws -> FerminRelayAttachmentUploadEnvelope {
        guard attachment.data.count <= FerminRelayHTTPConfiguration.maximumAttachmentBytes else {
            throw FerminRelayHTTPError.requestBodyTooLarge(
                actualBytes: attachment.data.count,
                maximumBytes: FerminRelayHTTPConfiguration.maximumAttachmentBytes
            )
        }
        let boundary = "FerminCodeBoundary-\(UUID().uuidString)"
        let body = multipartBody(attachment: attachment, boundary: boundary)
        let response = try await perform(
            endpoint: try .uploadAttachment(windowID),
            method: .post,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            includeAuthorization: true,
            timeout: configuration.commandTimeout,
            maximumRequestBytes: configuration.maximumUploadRequestBodyBytes
        )
        return try decode(FerminRelayAttachmentUploadEnvelope.self, from: response.body)
    }

    public func makeStreamRequest(lastEventID: UInt64? = nil) throws -> URLRequest {
        var request = try makeRequest(
            endpoint: .stream,
            method: .get,
            body: nil,
            contentType: nil,
            includeAuthorization: true,
            timeout: 0
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        FerminRelaySSECursor(lastEventID: lastEventID).applyLastEventID(to: &request)
        return request
    }

    public func stream(
        lastEventID: UInt64? = nil
    ) -> AsyncThrowingStream<FerminRelayStreamDelivery, Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(configuration.maximumBufferedSSEDeliveries)
        ) { continuation in
            let task = Task {
                do {
                    guard let streamTransport else {
                        throw FerminRelayHTTPError.streamTransportUnavailable
                    }
                    let request = try makeStreamRequest(lastEventID: lastEventID)
                    let connection = try await streamTransport.openEventStream(for: request)
                    guard (200..<300).contains(connection.statusCode) else {
                        throw FerminRelayHTTPError.httpStatus(
                            statusCode: connection.statusCode,
                            serverCode: nil,
                            message: "El stream devolvió HTTP \(connection.statusCode)."
                        )
                    }
                    var parser = FerminRelaySSEParser(
                        maximumFrameBytes: configuration.maximumSSEFrameBytes,
                        replayAfterEventID: lastEventID
                    )
                    var streamCursor = FerminRelaySSECursor(lastEventID: lastEventID)

                    func deliver(_ rawEvent: FerminRelaySSEEvent) throws {
                        let decoded = try FerminRelayStreamEventDecoder.decode(rawEvent)
                        let cursorAction: FerminRelaySSECursorAction
                        if case let .snapshot(snapshot) = decoded,
                           let snapshotCursor = snapshot.cursor,
                           let current = streamCursor.lastEventID,
                           snapshotCursor < current {
                            cursorAction = .reset(snapshotCursor)
                        } else if let eventID = rawEvent.id {
                            cursorAction = .commit(eventID)
                        } else {
                            cursorAction = .none
                        }
                        try streamCursor.apply(cursorAction)
                        let delivery = FerminRelayStreamDelivery(
                            eventID: rawEvent.id,
                            event: decoded,
                            rawEvent: rawEvent,
                            cursorAction: cursorAction
                        )
                        switch continuation.yield(delivery) {
                        case .enqueued:
                            return
                        case .dropped:
                            throw FerminRelayHTTPError.streamBufferOverflow(stage: .deliveries)
                        case .terminated:
                            throw CancellationError()
                        @unknown default:
                            throw FerminRelayHTTPError.streamBufferOverflow(stage: .deliveries)
                        }
                    }

                    for try await chunk in connection.chunks {
                        try Task.checkCancellation()
                        for event in try parser.feed(chunk) {
                            try deliver(event)
                        }
                    }
                    for event in try parser.finish() {
                        try deliver(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as FerminRelayHTTPError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(
                        throwing: FerminRelayHTTPError.transport(code: error.code.rawValue)
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func get<Response: Decodable>(
        _ endpoint: FerminCodeRelayEndpoint,
        as type: Response.Type,
        includeAuthorization: Bool = true
    ) async throws -> Response {
        let response = try await perform(
            endpoint: endpoint,
            method: .get,
            body: nil,
            contentType: nil,
            includeAuthorization: includeAuthorization,
            timeout: configuration.requestTimeout,
            maximumRequestBytes: configuration.maximumJSONRequestBodyBytes
        )
        return try decode(type, from: response.body)
    }

    private func sendWithoutBody<Response: Decodable>(
        _ endpoint: FerminCodeRelayEndpoint,
        method: FerminRelayHTTPMethod,
        as type: Response.Type
    ) async throws -> Response {
        let response = try await perform(
            endpoint: endpoint,
            method: method,
            body: nil,
            contentType: nil,
            includeAuthorization: true,
            timeout: configuration.commandTimeout,
            maximumRequestBytes: configuration.maximumJSONRequestBodyBytes
        )
        return try decode(type, from: response.body)
    }

    private func sendJSON<Body: Encodable, Response: Decodable>(
        _ endpoint: FerminCodeRelayEndpoint,
        method: FerminRelayHTTPMethod,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        let encoded = try JSONEncoder().encode(body)
        let response = try await perform(
            endpoint: endpoint,
            method: method,
            body: encoded,
            contentType: "application/json",
            includeAuthorization: true,
            timeout: configuration.commandTimeout,
            maximumRequestBytes: configuration.maximumJSONRequestBodyBytes
        )
        return try decode(type, from: response.body)
    }

    private func perform(
        endpoint: FerminCodeRelayEndpoint,
        method: FerminRelayHTTPMethod,
        body: Data?,
        contentType: String?,
        includeAuthorization: Bool,
        timeout: TimeInterval,
        maximumRequestBytes: Int
    ) async throws -> FerminRelayTransportResponse {
        if let body, body.count > maximumRequestBytes {
            throw FerminRelayHTTPError.requestBodyTooLarge(
                actualBytes: body.count,
                maximumBytes: maximumRequestBytes
            )
        }
        let request = try makeRequest(
            endpoint: endpoint,
            method: method,
            body: body,
            contentType: contentType,
            includeAuthorization: includeAuthorization,
            timeout: timeout
        )
        let response: FerminRelayTransportResponse
        do {
            response = try await transport.response(
                for: request,
                maximumBodyBytes: configuration.maximumResponseBodyBytes
            )
        } catch let error as FerminRelayHTTPError {
            throw error
        } catch let error as URLError {
            throw FerminRelayHTTPError.transport(code: error.code.rawValue)
        } catch {
            throw FerminRelayHTTPError.transport(code: (error as NSError).code)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw httpStatusError(response)
        }
        return response
    }

    private func makeRequest(
        endpoint: FerminCodeRelayEndpoint,
        method: FerminRelayHTTPMethod,
        body: Data?,
        contentType: String?,
        includeAuthorization: Bool,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(
            url: try endpoint.url(for: source),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if includeAuthorization {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw FerminRelayHTTPError.decoding(typeName: String(reflecting: type))
        }
    }

    private func httpStatusError(
        _ response: FerminRelayTransportResponse
    ) -> FerminRelayHTTPError {
        let bounded = response.body.prefix(configuration.maximumErrorMessageBytes)
        var serverCode: String?
        var message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        if let object = try? JSONSerialization.jsonObject(with: Data(bounded)) as? [String: Any] {
            serverCode = object["code"] as? String
            message = (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? message
        } else if let text = String(data: bounded, encoding: .utf8), !text.isEmpty {
            message = text
        }
        return .httpStatus(
            statusCode: response.statusCode,
            serverCode: serverCode,
            message: String(message.prefix(1_024))
        )
    }

    private func multipartBody(
        attachment: FerminRelayAttachmentUpload,
        boundary: String
    ) -> Data {
        let fileName = attachment.fileName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let mimeType = attachment.mimeType
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"image\"; filename=\"\(fileName)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(attachment.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

private final class FerminRelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct FerminRelayRenameRequest: Encodable {
    let name: String
    let idempotencyKey: String?
}

private struct FerminRelayRetryPromptRequest: Encodable {
    let messageID: String
    let idempotencyKey: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case idempotencyKey
    }
}

private struct FerminRelayResumeHistoryRequest: Encodable {
    let id: String
    let idempotencyKey: String?
}

private struct FerminRelayRecoverSessionRequest: Encodable {
    let id: String
    let idempotencyKey: String?
}
